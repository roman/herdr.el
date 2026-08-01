;;; herdr-term.el --- Mirror a herdr-owned pane  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes terminals

;; Package-Version: 0.1.0
;; Package-Requires: (
;;     (emacs   "29.1")
;;     (ghostel "0.48"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.
;;
;; This file is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Render a pane owned by the herdr server into a ghostel buffer, driven by
;; the `herdr terminal session observe' and `herdr terminal session control'
;; command line bridges.  Both ends run libghostty-vt, so content and style
;; survive with no fidelity loss.

;; The stream is newline delimited JSON:
;;
;;   {"type":"terminal.frame","seq":N,"full":BOOL,"width":W,"height":H,
;;    "bytes":"<base64 ANSI>"}
;;   {"type":"terminal.closed","reason":...}
;;
;; herdr sends one `full' frame on connect, a complete repaint and the only
;; authoritative resync point, then `full:false' deltas relative to the
;; previously composed frame, each stamped with an incrementing `seq'.  A
;; client that drops or misorders one delta diverges permanently, and the
;; protocol has no "request full frame" command, so the only resync is to
;; reconnect.  This module therefore treats a full frame as a hard reset,
;; refuses a delta that arrives before one, and reconnects on any `seq' gap
;; or unexpected stream exit.

;; herdr owns the pane, and with it the grid: every dimension this module
;; renders comes from a frame.  Nothing here resizes the terminal on its own
;; initiative, and ghostel's own window-driven resize is disowned, because a
;; local resize would leave the grid disagreeing with the frames still
;; arriving for it and no `seq' gap would mark the divergence.

;; Input reaches herdr through ghostel's own PTY sink rather than through
;; rebound keys, so that every ghostel and evil-ghostel input path works
;; alike.  See `herdr-term--ensure-input-bridge'.

;; Only the frame stream uses the command line, because it is the one
;; thing the JSON API does not carry.  Everything structural, such as
;; listing panes or creating a workspace, goes through `herdr-api'.

;;; Code:

(require 'ghostel)
(require 'seq)

(require 'herdr-api)

;;; Options

(defgroup herdr-term nil
  "Mirror a herdr-owned pane in an Emacs buffer."
  :group 'processes
  :prefix "herdr-term-")

(defcustom herdr-term-executable "herdr"
  "The herdr executable used to stream a pane's frames.
Only the frame stream runs herdr as a command; see `herdr-api-socket'
for the socket everything else uses.  A relative name is resolved
against the variable `exec-path' at the moment it is run, so
installing herdr later needs no reconfiguration."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'string)

(defcustom herdr-term-reconnect-min-interval 0.4
  "Minimum number of seconds between reconnects of one stream.
A reconnect requested sooner than this is deferred, never dropped."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'number)

(defcustom herdr-term-max-connect-attempts 3
  "How many times to retry a stream that exits without ever syncing.
This bounds recovery for a pane id that is invalid or has vanished,
which would otherwise be retried forever."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'natnum)

;;; Variables

(defvar-local herdr-term--process nil
  "Process running this buffer's frame stream.")

(defvar-local herdr-term--stdout ""
  "Trailing partial line of stream output, awaiting its newline.")

(defvar-local herdr-term--pane nil
  "Identifier of the herdr pane this buffer mirrors.")

(defvar-local herdr-term--writable nil
  "Non-nil when the stream is `control', which accepts input.")

(defvar-local herdr-term--last-seq nil
  "Sequence number of the last applied frame.
Nil before the current connection has applied its first full frame,
which makes it the record of whether that connection ever synced.")

(defvar-local herdr-term--rows nil
  "Number of rows in the grid herdr last reported for this pane.")

(defvar-local herdr-term--cols nil
  "Number of columns in the grid herdr last reported for this pane.")

(defvar-local herdr-term--last-reconnect nil
  "Value of `float-time' when this buffer last started a stream.")

(defvar-local herdr-term--reconnect-timer nil
  "Timer of a deferred reconnect, or nil when none is pending.")

(defvar-local herdr-term--fail-count 0
  "Number of successive connections that exited without ever syncing.")

(defvar-local herdr-term--close-reason nil
  "Reason reported by the last `terminal.closed' of the current stream.")

(defvar-local herdr-term--input-bridge nil
  "Process forwarding ghostel's PTY writes to the control stream.")

;;; Keymaps

(defvar-keymap herdr-term-command-mode-map
  :doc "Keymap for `herdr-term-command-mode'."
  "C-c C-l" #'herdr-term-resync
  "C-c C-k" #'herdr-term-close)

;;; Commands

;;;###autoload
(defun herdr-term-open (pane &optional writable)
  "Open a buffer mirroring herdr PANE.
With a prefix argument WRITABLE, attach the `control' stream so that
keystrokes reach the pane; otherwise attach `observe', which is read
only.  Re-opening a pane that is already streaming only displays its
buffer, because re-initializing would tear down a working terminal."
  (interactive
   (list (herdr-term--read-pane "Open pane: ") current-prefix-arg))
  (ghostel--load-module t)
  (let* ((name (format "*herdr:%s*" pane))
         (existing (get-buffer name)))
    (if (and existing
             (process-live-p
              (buffer-local-value 'herdr-term--process existing)))
        (pop-to-buffer existing)
      (herdr-term--setup (get-buffer-create name) pane writable))))

;;;###autoload
(defun herdr-term-new (&optional cwd)
  "Create a herdr terminal in CWD and open it writable.
This creates a herdr workspace whose root pane runs a shell, then
attaches a `control' stream to that pane, which is how a terminal is
driven from Emacs.  Interactively, a prefix argument prompts for CWD;
otherwise `default-directory' is used, falling back to the home
directory when the current buffer is remote."
  (interactive (list (when current-prefix-arg
                       (read-directory-name "New terminal cwd: "))))
  (let* ((directory
          (expand-file-name
           (or cwd (if (file-remote-p default-directory)
                       "~"
                     default-directory))))
         (result (herdr-api-request "workspace.create"
                                    (list :cwd directory)))
         (root (gethash "root_pane" result))
         (pane (and root (gethash "pane_id" root))))
    ;; The call itself succeeded; herdr just answered with a shape this
    ;; command cannot use, which is ours to report, not the API's.
    (unless pane
      (user-error "Herdr created no pane for %s" directory))
    (herdr-term-open pane t)))

(defun herdr-term-resync ()
  "Force a full-frame resync of the current buffer.
This also clears a previous give-up, so a stream that was abandoned
after `herdr-term-max-connect-attempts' can be retried."
  (interactive)
  (setq herdr-term--last-reconnect nil
        herdr-term--fail-count 0)
  (herdr-term--reconnect "manual"))

(defun herdr-term-close ()
  "Kill this buffer, and with it its stream."
  (interactive)
  (kill-buffer (current-buffer)))

(define-minor-mode herdr-term-command-mode
  "Bind the client-local commands of a herdr terminal buffer.
These are the commands that act on the Emacs side of the mirror, such
as resync and close, as opposed to keys that are forwarded to the pane."
  :interactive nil)

;;; Setup and Teardown

(defun herdr-term--setup (buffer pane writable)
  "Display BUFFER, attach it to herdr PANE and start its stream.
WRITABLE selects the `control' stream over `observe'.  The grid is
first sized to the buffer's window so that the connect asks for
sensible dimensions; the first full frame then re-initializes it to
herdr's authoritative ones."
  (with-current-buffer buffer
    ;; Re-attaching to a buffer whose stream died leaves its processes and
    ;; timers running, and `ghostel-mode' is about to discard the variables
    ;; that still reference them.
    (herdr-term--teardown)
    (ghostel-mode))
  (pop-to-buffer buffer (append display-buffer--same-window-action
                                '((category . comint))))
  (let* ((window (get-buffer-window buffer t))
         (rows (if window
                   (max 1 (with-selected-window window
                            (floor (window-screen-lines))))
                 24))
         (cols (if window (max 1 (window-max-chars-per-line window)) 80)))
    (with-current-buffer buffer
      (setq herdr-term--pane pane
            herdr-term--writable writable
            herdr-term--last-seq nil
            herdr-term--last-reconnect nil
            herdr-term--fail-count 0)
      (herdr-term--reset-term rows cols)
      (herdr-term-command-mode 1)
      (add-hook 'kill-buffer-hook #'herdr-term--teardown nil t)
      (herdr-term--start-stream buffer)))
  buffer)

(defun herdr-term--teardown ()
  "Stop this buffer's stream, input bridge and pending reconnect."
  (herdr-term--kill-process)
  (herdr-term--cancel-reconnect)
  (herdr-term--kill-input-bridge))

;;; Stream Lifecycle

(defun herdr-term--start-stream (buffer)
  "Kill any stream attached to BUFFER and start a fresh one.
Return the new process.  A fresh connect always begins with a full
frame, so this doubles as the only resync the protocol offers."
  (with-current-buffer buffer
    (herdr-term--kill-process)
    (herdr-term--cancel-reconnect)
    (setq herdr-term--last-seq nil
          herdr-term--stdout ""
          herdr-term--close-reason nil
          herdr-term--last-reconnect (float-time))
    (let* ((subcommand (if herdr-term--writable "control" "observe"))
           (arguments
            (append (list "terminal" "session" subcommand herdr-term--pane
                          "--rows" (number-to-string
                                    (or herdr-term--rows 24))
                          "--cols" (number-to-string
                                    (or herdr-term--cols 80)))
                    ;; Without `--takeover', `control' detaches at once,
                    ;; answering with a single `terminal.closed' and no
                    ;; frames at all.  We are the legitimate owner
                    ;; reconnecting to our own session, so always take over.
                    (and herdr-term--writable '("--takeover"))))
           (process (make-process
                     :name (format "herdr-term:%s" herdr-term--pane)
                     ;; Deliberately process-less: `process-send-string'
                     ;; resolves a nil process to the current buffer's, and
                     ;; ghostel's module falls back to exactly that call
                     ;; whenever `ghostel--process' is nil.  Adopting this
                     ;; process as the buffer's would let a stray keypress
                     ;; write raw bytes into a stream that speaks JSON.
                     :buffer nil
                     :command (cons herdr-term-executable arguments)
                     :connection-type 'pipe
                     :coding 'binary
                     :noquery t
                     :filter #'herdr-term--filter
                     :sentinel #'herdr-term--sentinel)))
      (process-put process 'herdr-term-buffer buffer)
      (setq herdr-term--process process)
      (herdr-term--update-mode-line)
      process)))

(defun herdr-term--kill-process ()
  "Delete this buffer's stream process without waking its sentinel.
Detaching the sentinel and filter first is what tells an intentional
teardown apart from herdr dropping the stream.  Left attached, the
sentinel would fire after teardown and race a spurious reconnect
against the one the caller is about to make."
  (when (process-live-p herdr-term--process)
    (set-process-sentinel herdr-term--process #'ignore)
    (set-process-filter herdr-term--process #'ignore)
    (delete-process herdr-term--process)))

(defun herdr-term--sentinel (process event)
  "Recover the stream of PROCESS after EVENT reported that it dropped.
An intentional teardown detaches this sentinel first, so reaching here
always means herdr closed the stream on us.  A stream that had already
synced is reconnected as a transient drop.  One that exits without ever
syncing is retried `herdr-term-max-connect-attempts' times and then
abandoned, because an invalid or vanished pane never becomes valid."
  (let ((buffer (process-get process 'herdr-term-buffer)))
    (when (and (buffer-live-p buffer)
               (memq (process-status process) '(exit signal)))
      (with-current-buffer buffer
        (let ((detail (or herdr-term--close-reason (string-trim event))))
          (if herdr-term--last-seq
              (herdr-term--reconnect (format "stream exited: %s" detail))
            (setq herdr-term--fail-count (1+ herdr-term--fail-count))
            (if (herdr-term--gave-up-p)
                (progn
                  (herdr-term--update-mode-line)
                  (message
                   "herdr-term[%s]: gave up after %d tries (%s); %s retries"
                   herdr-term--pane herdr-term--fail-count detail
                   (substitute-command-keys "\\[herdr-term-resync]")))
              (herdr-term--reconnect
               (format "connect failed: %s (attempt %d/%d)" detail
                       herdr-term--fail-count
                       herdr-term-max-connect-attempts)))))))))

(defun herdr-term--gave-up-p ()
  "Return non-nil when this buffer stopped retrying its stream."
  (>= herdr-term--fail-count herdr-term-max-connect-attempts))

(defun herdr-term--reconnect (reason)
  "Reconnect this buffer's stream to obtain a fresh full frame.
REASON is reported to the user.  The dying stream is dropped at once,
so that no later frame of its own can reach the grid, but the restart
is rate limited to one per `herdr-term-reconnect-min-interval'.  A
restart that must wait is deferred rather than dropped, because the
caller is often a sentinel whose process is already gone: dropping it
would strand the buffer on a dead stream."
  (herdr-term--kill-process)
  (let* ((buffer (current-buffer))
         (since (and herdr-term--last-reconnect
                     (- (float-time) herdr-term--last-reconnect)))
         (wait (if since (- herdr-term-reconnect-min-interval since) 0)))
    (cond
      ((<= wait 0)
       (message "herdr-term[%s]: reconnecting (%s)" herdr-term--pane reason)
       (herdr-term--start-stream buffer))
      ((not (timerp herdr-term--reconnect-timer))
       (message "herdr-term[%s]: reconnecting in %.1fs (%s)"
                herdr-term--pane wait reason)
       (setq herdr-term--reconnect-timer
             (run-at-time wait nil #'herdr-term--reconnect-deferred
                          buffer))))))

(defun herdr-term--reconnect-deferred (buffer)
  "Run the reconnect that BUFFER deferred to stay inside the rate limit."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq herdr-term--reconnect-timer nil)
      (herdr-term--start-stream buffer))))

(defun herdr-term--cancel-reconnect ()
  "Cancel this buffer's deferred reconnect, if one is pending."
  (when (timerp herdr-term--reconnect-timer)
    (cancel-timer herdr-term--reconnect-timer))
  (setq herdr-term--reconnect-timer nil))

;;; Frame Application

(defun herdr-term--filter (process chunk)
  "Accumulate CHUNK from PROCESS and apply each complete message in it."
  (let ((buffer (process-get process 'herdr-term-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq herdr-term--stdout (concat herdr-term--stdout chunk))
        (let* ((parts (split-string herdr-term--stdout "\n"))
               (complete (butlast parts)))
          (setq herdr-term--stdout (car (last parts)))
          ;; A reconnect mid-chunk kills this stream, so the rest of
          ;; `complete' belongs to a dead one and must not reach the new
          ;; grid.
          (catch 'herdr-term--resynced
            (dolist (line complete)
              (unless (string-empty-p line)
                (let ((object
                       (ignore-errors
                         (json-parse-string line
                                            :false-object nil
                                            :null-object nil))))
                  (when (and (hash-table-p object)
                             (eq 'resync
                                 (herdr-term--apply-message buffer object)))
                    (throw 'herdr-term--resynced nil)))))))))))

(defun herdr-term--apply-message (buffer object)
  "Apply one decoded stream message OBJECT to BUFFER.
Return the symbol `resync' when the message triggered a reconnect, so
that the caller can stop feeding it the now stale remainder of the same
chunk."
  (with-current-buffer buffer
    (pcase (gethash "type" object)
      ("terminal.frame" (herdr-term--apply-frame object))
      ("terminal.closed" (herdr-term--note-closed object)))))

(defun herdr-term--apply-frame (object)
  "Apply frame OBJECT to the current buffer.
Return the symbol `resync' when the frame triggered a reconnect."
  (let ((seq (gethash "seq" object))
        (full (gethash "full" object))
        (rows (gethash "height" object))
        (cols (gethash "width" object))
        (payload (gethash "bytes" object)))
    (prog1
        (cond
          ((null payload)
           (herdr-term--reconnect "frame without bytes")
           'resync)
          (full
           (herdr-term--apply-full seq rows cols payload))
          ((null herdr-term--last-seq)
           (herdr-term--reconnect "delta before initial full frame")
           'resync)
          ((/= seq (1+ herdr-term--last-seq))
           (herdr-term--reconnect
            (format "seq gap %s->%s" herdr-term--last-seq seq))
           'resync)
          (t
           (herdr-term--apply-delta seq rows cols payload)))
      (herdr-term--update-mode-line))))

(defun herdr-term--apply-full (seq rows cols payload)
  "Reset the grid to ROWS by COLS and paint base64 PAYLOAD as frame SEQ.
Return the symbol `resync' when applying failed, having already asked
for a fresh stream: a full frame is authoritative, so a failure leaves
the grid in a state only a new connection can resolve."
  (condition-case err
      (progn
        (herdr-term--reset-term rows cols)
        (herdr-term--paint (base64-decode-string payload))
        (setq herdr-term--last-seq seq
              herdr-term--fail-count 0)
        nil)
    (error (herdr-term--reconnect (format "full apply failed: %S" err))
           'resync)))

(defun herdr-term--apply-delta (seq rows cols payload)
  "Paint base64 PAYLOAD as frame SEQ, resizing to ROWS by COLS first.
Return the symbol `resync' when applying failed.  A delta assumes the
grid the previous frame left behind, so a malformed one diverges
exactly as a dropped frame does and recovers the same way."
  (condition-case err
      (progn
        (herdr-term--maybe-resize rows cols)
        (herdr-term--paint (base64-decode-string payload))
        (setq herdr-term--last-seq seq)
        nil)
    (error (herdr-term--reconnect (format "delta apply failed: %S" err))
           'resync)))

(defun herdr-term--note-closed (object)
  "Report the `reason' carried by `terminal.closed' message OBJECT.
Recovery belongs to the process sentinel, so this only records.  It
leaves `herdr-term--last-seq' intact in particular: clearing it would
strand a still live stream on \"delta before initial full frame\" for
every frame that follows."
  (setq herdr-term--close-reason (gethash "reason" object))
  (message "herdr-term[%s]: stream closed (%s)"
           herdr-term--pane herdr-term--close-reason)
  nil)

(defun herdr-term--maybe-resize (rows cols)
  "Resize this buffer's grid to ROWS by COLS when they changed.
A frame's dimensions are authoritative: painting a repaint sized for a
different grid would place cells outside it."
  (when (and rows cols
             (or (not (eql rows herdr-term--rows))
                 (not (eql cols herdr-term--cols))))
    (ghostel--set-size-with-cell-dims ghostel--term
                                      (max 1 rows) (max 1 cols))
    (setq herdr-term--rows rows
          herdr-term--cols cols)))

(defun herdr-term--reset-term (rows cols)
  "Recreate this buffer's ghostel terminal at ROWS by COLS.
A full frame is authoritative, so it must land on a grid as clean as
the one a new buffer gets.  Painting it onto a reused grid resets
neither the scroll region, nor the saved cursor, nor an alternate
screen save left behind by an application herdr flattened away, so a
grid that had drifted from herdr's would stay wrong.  Recreating it
guarantees parity."
  (let ((rows (max 1 (or rows herdr-term--rows 24)))
        (cols (max 1 (or cols herdr-term--cols 80))))
    ;; `ghostel--init-buffer' refuses to run while `ghostel--process' holds
    ;; a live process, and on a writable buffer that slot is where the input
    ;; bridge lives.  Shadow the slot rather than retiring the bridge, whose
    ;; unflushed bytes are keystrokes the user already typed.
    (let ((ghostel--process nil))
      (ghostel--init-buffer (current-buffer) rows cols))
    ;; ghostel keeps `ghostel--adjust-size' on the buffer-local hook, and it
    ;; acts whenever `ghostel--process' is live, which the input bridge makes
    ;; true.  It would resize the grid to the Emacs window while herdr went
    ;; on sending frames sized for its own, a divergence no `seq' gap marks.
    (remove-hook 'window-size-change-functions #'ghostel--adjust-size t)
    (setq herdr-term--rows rows
          herdr-term--cols cols)
    (when herdr-term--writable
      (herdr-term--ensure-input-bridge))))

(defun herdr-term--paint (bytes)
  "Feed BYTES to this buffer's ghostel terminal and repaint it.
The repaint is forced because herdr wraps frames in synchronized output
\(mode 2026), under which a deferred redraw would leave the buffer one
frame behind."
  (ghostel--write-vt ghostel--term bytes)
  (ghostel--redraw-now (current-buffer) t))

;;; Input

(defun herdr-term--ensure-input-bridge ()
  "Point `ghostel--process' at a live bridge to the control stream.
ghostel drives input the way any terminal does: its handlers and its
module key encoder write bytes to the terminal's PTY, which with no
native process is whatever `ghostel--process' holds.  Setting that to a
`cat' process and forwarding what ghostel writes to it is what makes
every input path work alike, including the encoder paths for backspace,
arrows and function keys that write inside the module and so cannot be
intercepted by advising a send function or rebinding a key.

This is idempotent, and must run after every `ghostel--init-buffer',
which resets `ghostel--process' to nil."
  (unless (process-live-p herdr-term--input-bridge)
    (let ((buffer (current-buffer)))
      (setq herdr-term--input-bridge
            (make-process
             :name (format "herdr-term-input:%s" herdr-term--pane)
             :buffer nil
             :command '("cat")
             :connection-type 'pipe
             :coding 'binary
             :noquery t
             :filter (lambda (_process bytes)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (herdr-term--send-input bytes))))))))
  (setq ghostel--process herdr-term--input-bridge))

(defun herdr-term--kill-input-bridge ()
  "Delete this buffer's input bridge, releasing `ghostel--process'."
  (when (process-live-p herdr-term--input-bridge)
    (delete-process herdr-term--input-bridge))
  (setq herdr-term--input-bridge nil
        ghostel--process nil))

(defun herdr-term--send-input (bytes)
  "Forward raw terminal input BYTES to the stream as `terminal.input'."
  (when (and herdr-term--writable
             (process-live-p herdr-term--process))
    (let ((unibyte (if (multibyte-string-p bytes)
                       (encode-coding-string bytes 'utf-8)
                     bytes)))
      (process-send-string
       herdr-term--process
       (concat (json-serialize
                (list :type "terminal.input"
                      :bytes (base64-encode-string unibyte t)))
               "\n")))))

;;; Presentation

(defun herdr-term--update-mode-line ()
  "Refresh `mode-line-process' from this buffer's stream state."
  (setq mode-line-process
        (format " herdr:%s[%s%s]"
                herdr-term--pane
                (if herdr-term--writable "rw" "ro")
                (cond
                  ((herdr-term--gave-up-p) " dead")
                  (herdr-term--last-seq
                   (format " %d" herdr-term--last-seq))
                  (t " …"))))
  (force-mode-line-update))

;;; Panes

(defun herdr-term--panes ()
  "Return an alist of (PANE-ID . INFO) for every live herdr pane.
INFO is the hash-table herdr reported for that pane."
  (let ((panes (gethash "panes" (herdr-api-request "pane.list"))))
    (seq-map (lambda (pane) (cons (gethash "pane_id" pane) pane))
             (or panes []))))

(defun herdr-term--read-pane (prompt)
  "Read the identifier of a live herdr pane, prompting with PROMPT.
Candidates are annotated with the pane's working directory, its
detected agent and its workspace."
  (let ((panes (herdr-term--panes)))
    ;; A session with no panes is an ordinary state herdr reports happily,
    ;; not a failure of the call, so say what to do about it.
    (unless panes
      (user-error "No live herdr panes; create one with %s"
                  (substitute-command-keys "\\[herdr-term-new]")))
    (let* ((annotate
            (lambda (id)
              (when-let* ((pane (cdr (assoc id panes))))
                (let ((cwd (gethash "cwd" pane))
                      (agent (gethash "agent" pane))
                      (workspace (gethash "workspace_id" pane)))
                  (concat "  " (or cwd "")
                          (if agent (format " (%s)" agent) "")
                          (if workspace (format " [%s]" workspace) ""))))))
           (completion-extra-properties
            (list :annotation-function annotate)))
      (completing-read prompt (mapcar #'car panes) nil t))))

;;; _
(provide 'herdr-term)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-term.el ends here
