;;; herdr-term-tests.el --- Tests for herdr-term  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

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

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-term)

;;; Fixtures

(defvar herdr-term-test-painted nil
  "Byte strings handed to the ghostel terminal, most recent first.")

(defvar herdr-term-test-resets nil
  "One (ROWS . COLS) per grid rebuild, most recent first.")

(defvar herdr-term-test-resizes nil
  "One (ROWS . COLS) per resize without a rebuild, most recent first.")

(defvar herdr-term-test-streams 0
  "How many times a fresh stream was started.")

(defvar herdr-term-test-sent nil
  "Strings written to the stream process, most recent first.")

(defmacro herdr-term-with-test-buffer (&rest body)
  "Evaluate BODY in a herdr terminal buffer that talks to nothing.
The ghostel terminal, the stream process and the input bridge are each
replaced by a recorder, so that the frame state machine can be driven
with hand-written messages and needs no server, no PTY and no native
module.  BODY may read `herdr-term-test-painted',
`herdr-term-test-resets', `herdr-term-test-resizes',
`herdr-term-test-streams' and `herdr-term-test-sent', and may set any
`herdr-term--' buffer-local before acting.

The buffer of a test that fails is left behind for inspection."
  (declare (indent 0) (debug t))
  (let ((buffer (make-symbol "buffer"))
        (process (make-symbol "process")))
    `(let* ((,buffer (generate-new-buffer " *herdr-term-test*"))
            (,process (make-pipe-process :name "herdr-term-test"
                                         :noquery t
                                         :filter #'ignore))
            (herdr-term-test-painted nil)
            (herdr-term-test-resets nil)
            (herdr-term-test-resizes nil)
            (herdr-term-test-streams 0)
            (herdr-term-test-sent nil))
       (process-put ,process 'herdr-term-buffer ,buffer)
       (cl-letf (((symbol-function 'ghostel--init-buffer)
                  (lambda (_buffer &optional rows cols)
                    ;; ghostel refuses to reinitialize a buffer whose
                    ;; terminal still owns a process.  Reproducing that
                    ;; refusal is what lets a test catch a reset that
                    ;; forgot to release the input bridge first.
                    (when (process-live-p ghostel--process)
                      (user-error
                       "Buffer %s already has a running ghostel process"
                       (buffer-name)))
                    (setq ghostel--process nil)
                    ;; Reproduced because it is the trap: the real one
                    ;; claims the buffer takes terminal input again
                    ;; without running the teardown that would make it
                    ;; true.
                    (setq ghostel--input-mode 'semi-char)
                    (push (cons rows cols) herdr-term-test-resets)))
                 ((symbol-function 'ghostel--set-size-with-cell-dims)
                  (lambda (_term rows cols)
                    (push (cons rows cols) herdr-term-test-resizes)))
                 ((symbol-function 'ghostel--write-vt)
                  (lambda (_term bytes)
                    (push bytes herdr-term-test-painted)))
                 ((symbol-function 'ghostel--redraw-now) #'ignore)
                 ((symbol-function 'herdr-term--ensure-input-bridge) #'ignore)
                 ((symbol-function 'process-send-string)
                  (lambda (_process string)
                    (push string herdr-term-test-sent)))
                 ((symbol-function 'herdr-term--start-stream)
                  (lambda (_buffer) (cl-incf herdr-term-test-streams))))
         (condition-case err
             (prog1 (with-current-buffer ,buffer
                      (setq herdr-term--pane "w1:p1"
                            herdr-term--process ,process)
                      ,@body)
               (with-current-buffer ,buffer
                 (herdr-term--cancel-reconnect))
               (delete-process ,process)
               (kill-buffer ,buffer))
           (error (message "Keeping test buffer:\n  %s" ,buffer)
                  (delete-process ,process)
                  (signal (car err) (cdr err))))))))

(defun herdr-term-test-frame (seq full payload &optional rows cols)
  "Return a `terminal.frame' line carrying PAYLOAD as frame SEQ.
FULL selects a full repaint over a delta.  ROWS and COLS default to 24
by 80."
  (json-serialize (list :type "terminal.frame"
                        :seq seq
                        :full (if full t :false)
                        :height (or rows 24)
                        :width (or cols 80)
                        :bytes (base64-encode-string payload t))))

(defun herdr-term-test-end-stream (process event)
  "Drive the sentinel for PROCESS as though it had exited with EVENT.
The fixture's stand-in is a pipe process, and a deleted one of those
reports `closed' where the real stream process, a subprocess, reports
`exit' — which is the status the sentinel acts on.

Only PROCESS is answered for.  `process-live-p' is Lisp and asks
`process-status', so a stub that answered for every process would make
each one look dead, and the teardown would walk past the input bridge
it is supposed to kill."
  (delete-process process)
  (cl-letf* ((status (symbol-function 'process-status))
             ((symbol-function 'process-status)
              (lambda (other)
                (if (eq other process) 'exit (funcall status other)))))
    (herdr-term--sentinel process event)))

(defun herdr-term-test-apply (line)
  "Apply the message on LINE to the current buffer, as the filter would."
  (herdr-term--apply-message
   (current-buffer)
   (json-parse-string line :false-object nil :null-object nil)))

;;; Buffer Names

(ert-deftest herdr-term--buffer-name:starts-with-the-agent-title ()
  "Buffer lists distinguish terminals by task before opaque pane id."
  (let ((herdr-session--snapshot
         (json-parse-string
          (json-serialize
           '(:agents
             [(:pane_id "w1:p1" :name "fix-agent-rows"
               :agent "codex")])))))
    (should (equal (herdr-term--buffer-name "w1:p1")
                   "*herdr:fix-agent-rows [w1:p1]*"))))

(ert-deftest herdr-term--buffer-name:falls-back-to-the-pane ()
  "A pane with no agent metadata keeps the stable historical name."
  (let ((herdr-session--snapshot nil))
    (should (equal (herdr-term--buffer-name "w1:p1")
                   "*herdr:w1:p1*"))))

(ert-deftest herdr-term--rename-buffers:follows-a-new-title ()
  "An open terminal adopts a title changed after it was opened."
  (let ((buffer (generate-new-buffer "*herdr:w1:p1*"))
        (herdr-session--snapshot
         (json-parse-string
          (json-serialize
           '(:agents
             [(:pane_id "w1:p1" :name "renamed-task"
               :agent "codex")])))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq herdr-term--pane "w1:p1"))
          (herdr-term--rename-buffers)
          (should (equal (buffer-name buffer)
                         "*herdr:renamed-task [w1:p1]*")))
      (kill-buffer buffer))))

(ert-deftest herdr-term--update-directories:follows-the-pane-cwd ()
  "An open terminal adopts its pane's current working directory."
  (let ((buffer (generate-new-buffer " *herdr-directory-test*"))
        (directory (make-temp-file "herdr-term-directory-" t)))
    (unwind-protect
        (let ((herdr-session--snapshot
               (json-parse-string
                (json-serialize
                 (list :panes
                       (vector (list :pane_id "w1:p1"
                                     :cwd directory)))))))
          (with-current-buffer buffer
            (setq herdr-term--pane "w1:p1"
                  default-directory user-emacs-directory
                  list-buffers-directory user-emacs-directory))
          (herdr-term--update-directories)
          (with-current-buffer buffer
            (should
             (equal default-directory
                    (file-name-as-directory directory)))
            (should (equal list-buffers-directory
                           default-directory))))
      (kill-buffer buffer)
      (delete-directory directory))))

(ert-deftest herdr-term--setup:adopts-a-known-pane-cwd ()
  "Opening an existing pane starts in the directory Herdr reports."
  (let ((buffer (generate-new-buffer " *herdr-setup-directory-test*"))
        (directory (make-temp-file "herdr-term-setup-directory-" t)))
    (unwind-protect
        (let ((herdr-session--snapshot
               (json-parse-string
                (json-serialize
                 (list :panes
                       (vector (list :pane_id "w1:p1"
                                     :cwd directory)))))))
          (with-current-buffer buffer
            (setq default-directory user-emacs-directory
                  list-buffers-directory user-emacs-directory))
          (cl-letf (((symbol-function 'herdr-term--teardown) #'ignore)
                    ((symbol-function 'ghostel-mode) #'ignore)
                    ((symbol-function 'pop-to-buffer) #'ignore)
                    ((symbol-function 'get-buffer-window) #'ignore)
                    ((symbol-function 'herdr-term--reset-term) #'ignore)
                    ((symbol-function 'herdr-term-command-mode) #'ignore)
                    ((symbol-function 'herdr-term--start-stream) #'ignore))
            (should (eq (herdr-term--setup buffer "w1:p1" nil)
                        buffer)))
          (with-current-buffer buffer
            (should
             (equal default-directory
                    (file-name-as-directory directory)))
            (should (equal list-buffers-directory
                           default-directory))))
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook #'herdr-term--teardown t))
      (kill-buffer buffer)
      (delete-directory directory))))

;;; Stream Framing

(ert-deftest herdr-term--filter:buffers-partial-line ()
  "A message split across chunks is applied once, after its newline."
  (herdr-term-with-test-buffer
    (let ((line (herdr-term-test-frame 1 t "hi")))
      (herdr-term--filter herdr-term--process (substring line 0 20))
      (should (null herdr-term--last-seq))
      (should (equal herdr-term--stdout (substring line 0 20)))
      (herdr-term--filter herdr-term--process
                          (concat (substring line 20) "\n"))
      (should (eql herdr-term--last-seq 1))
      (should (equal herdr-term-test-painted '("hi")))
      (should (equal herdr-term--stdout "")))))

(ert-deftest herdr-term--filter:applies-several-frames ()
  "Every complete message in one chunk is applied, in order."
  (herdr-term-with-test-buffer
    (herdr-term--filter
     herdr-term--process
     (concat (herdr-term-test-frame 1 t "a") "\n"
             (herdr-term-test-frame 2 nil "b") "\n"
             (herdr-term-test-frame 3 nil "c") "\n"))
    (should (eql herdr-term--last-seq 3))
    (should (equal (reverse herdr-term-test-painted) '("a" "b" "c")))))

(ert-deftest herdr-term--filter:abandons-chunk-after-resync ()
  "Frames behind a resync belong to the dead stream and are dropped."
  (herdr-term-with-test-buffer
    (herdr-term--filter
     herdr-term--process
     (concat (herdr-term-test-frame 1 t "a") "\n"
             ;; Seq 3 gaps over 2, which resyncs.  Seq 4 is then stale.
             (herdr-term-test-frame 3 nil "b") "\n"
             (herdr-term-test-frame 4 nil "c") "\n"))
    (should (equal (reverse herdr-term-test-painted) '("a")))
    (should (eql herdr-term-test-streams 1))))

(ert-deftest herdr-term--filter:ignores-malformed-line ()
  "A line that is not JSON is skipped without disturbing the stream."
  (herdr-term-with-test-buffer
    (herdr-term--filter
     herdr-term--process
     (concat "{not json" "\n"
             (herdr-term-test-frame 1 t "a") "\n"))
    (should (eql herdr-term--last-seq 1))
    (should (equal herdr-term-test-painted '("a")))))

;;; Frame Application

(ert-deftest herdr-term--apply-frame:full-syncs ()
  "A full frame paints, records its seq and adopts its dimensions."
  (herdr-term-with-test-buffer
    (should (null (herdr-term-test-apply
                   (herdr-term-test-frame 7 t "x" 30 100))))
    (should (eql herdr-term--last-seq 7))
    (should (eql herdr-term--rows 30))
    (should (eql herdr-term--cols 100))
    (should (equal herdr-term-test-resets '((30 . 100))))
    (should (equal herdr-term-test-painted '("x")))))

(ert-deftest herdr-term--apply-frame:full-rebuilds-grid ()
  "Every full frame rebuilds the grid rather than reusing it.
A reused grid keeps drift that the flattened stream cannot undo."
  (herdr-term-with-test-buffer
    (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))
    (herdr-term-test-apply (herdr-term-test-frame 2 t "b"))
    (should (eql (length herdr-term-test-resets) 2))
    (should (null herdr-term-test-resizes))))

(ert-deftest herdr-term--apply-frame:delta-advances ()
  "A delta at the next seq paints without rebuilding the grid."
  (herdr-term-with-test-buffer
    (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))
    (should (null (herdr-term-test-apply
                   (herdr-term-test-frame 2 nil "b"))))
    (should (eql herdr-term--last-seq 2))
    (should (eql (length herdr-term-test-resets) 1))
    (should (equal (reverse herdr-term-test-painted) '("a" "b")))))

(ert-deftest herdr-term--apply-frame:delta-before-full-resyncs ()
  "A delta with no full frame behind it has no grid to apply to."
  (herdr-term-with-test-buffer
    (should (eq 'resync (herdr-term-test-apply
                         (herdr-term-test-frame 1 nil "a"))))
    (should (null herdr-term--last-seq))
    (should (null herdr-term-test-painted))
    (should (eql herdr-term-test-streams 1))))

(ert-deftest herdr-term--apply-frame:seq-gap-resyncs ()
  "A gap means a lost delta, and deltas do not survive a loss."
  (herdr-term-with-test-buffer
    (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))
    (should (eq 'resync (herdr-term-test-apply
                         (herdr-term-test-frame 3 nil "c"))))
    (should (eql herdr-term--last-seq 1))
    (should (eql herdr-term-test-streams 1))))

(ert-deftest herdr-term--apply-frame:missing-bytes-resyncs ()
  "A frame with no payload leaves the grid unexplained."
  (herdr-term-with-test-buffer
    (should (eq 'resync
                (herdr-term-test-apply
                 (json-serialize '(:type "terminal.frame" :seq 1
                                   :full t :height 24 :width 80)))))
    (should (eql herdr-term-test-streams 1))))

(ert-deftest herdr-term--apply-frame:full-clears-fail-count ()
  "Syncing proves the pane is reachable, so the retry budget resets."
  (herdr-term-with-test-buffer
    (setq herdr-term--fail-count 2)
    (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))
    (should (eql herdr-term--fail-count 0))
    (should (not (herdr-term--gave-up-p)))))

(ert-deftest herdr-term--reset-term:survives-live-input-bridge ()
  "A full frame applies to a writable buffer, whose PTY sink is live.
ghostel refuses to reinitialize a buffer that still owns a process, and
on a writable buffer that process is the input bridge.  A reset that
does not account for it fails every full frame and reconnects forever.
The bridge must also outlive the reset, because the bytes it has not
flushed yet are keystrokes the user already typed."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t
          ghostel--process herdr-term--process)
    (should (null (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))))
    (should (eql herdr-term--last-seq 1))
    (should (eql herdr-term-test-streams 0))
    (should (eq ghostel--process herdr-term--process))))

(ert-deftest herdr-term--reset-term:restores-the-terminal-keymap ()
  "Every input mode is left behind before the grid is rebuilt.
A rebuild claims the buffer takes terminal input again without running
the teardown for the mode it leaves, so the keymap, the read-only
barrier and the cursor of a copy, Emacs or char mode survive it.  The
buffer is then wedged for good, its keys running a map that no longer
matches what it says it is, because `ghostel-semi-char-mode' returns
early on the variable the rebuild already set."
  (herdr-term-with-test-buffer
    (ghostel-mode)
    (dolist (enter (list #'ghostel-copy-mode #'ghostel-emacs-mode
                         #'ghostel-char-mode))
      (funcall enter)
      (should (not (eq (current-local-map) ghostel-semi-char-mode-map)))
      (herdr-term--reset-term 24 80)
      (should (eq (current-local-map) ghostel-semi-char-mode-map))
      (should (eq ghostel--input-mode 'semi-char))
      ;; Char mode's own override outranks `herdr-term-command-mode-map'
      ;; through `emulation-mode-map-alists', so a stale one swallows the
      ;; resync that is the last way back.
      (should (not ghostel--char-mode-override-active)))))

(ert-deftest herdr-term--reset-term:disowns-local-resize ()
  "Herdr owns the grid, so ghostel's window-driven resize is removed.
Left installed it would resize to the Emacs window while herdr kept
sending frames sized for its own, a divergence no seq gap marks."
  (herdr-term-with-test-buffer
    (add-hook 'window-size-change-functions #'ghostel--adjust-size nil t)
    (herdr-term--reset-term 24 80)
    (should (null (memq #'ghostel--adjust-size
                        window-size-change-functions)))))

(ert-deftest herdr-term--maybe-resize:only-on-change ()
  "Resizing to the size already rendered is not a resize."
  (herdr-term-with-test-buffer
    (setq herdr-term--rows 24 herdr-term--cols 80)
    (herdr-term--maybe-resize 24 80)
    (should (null herdr-term-test-resizes))
    (herdr-term--maybe-resize 30 80)
    (should (equal herdr-term-test-resizes '((30 . 80))))
    (should (eql herdr-term--rows 30))))

(ert-deftest herdr-term--note-closed:keeps-last-seq ()
  "A close notice reports; the sentinel recovers.
Clearing the seq here would strand a still live stream on \"delta
before initial full frame\" for every frame that follows."
  (herdr-term-with-test-buffer
    (herdr-term-test-apply (herdr-term-test-frame 1 t "a"))
    (should (null (herdr-term-test-apply
                   (json-serialize '(:type "terminal.closed"
                                     :reason "detached")))))
    (should (eql herdr-term--last-seq 1))
    (should (equal herdr-term--close-reason "detached"))
    (should (eql herdr-term-test-streams 0))))

;;; Reconnect

(ert-deftest herdr-term--reconnect:starts-stream-when-idle ()
  "A first reconnect does not wait."
  (herdr-term-with-test-buffer
    (herdr-term--reconnect "test")
    (should (eql herdr-term-test-streams 1))
    (should (null herdr-term--reconnect-timer))))

(ert-deftest herdr-term--reconnect:defers-when-recent ()
  "A reconnect inside the rate limit is deferred, never dropped."
  (herdr-term-with-test-buffer
    (setq herdr-term--last-reconnect (float-time))
    (herdr-term--reconnect "test")
    (should (eql herdr-term-test-streams 0))
    (should (timerp herdr-term--reconnect-timer))))

(ert-deftest herdr-term--reconnect:defers-only-once ()
  "A burst of reconnects arms one timer, not one timer per frame."
  (herdr-term-with-test-buffer
    (setq herdr-term--last-reconnect (float-time))
    (herdr-term--reconnect "first")
    (let ((timer herdr-term--reconnect-timer))
      (herdr-term--reconnect "second")
      (herdr-term--reconnect "third")
      (should (eq timer herdr-term--reconnect-timer)))))

;;; Give Up

(ert-deftest herdr-term--gave-up-p:counts-attempts ()
  "Giving up is exactly the retry budget being spent."
  (herdr-term-with-test-buffer
    (setq herdr-term--fail-count (1- herdr-term-max-connect-attempts))
    (should (not (herdr-term--gave-up-p)))
    (setq herdr-term--fail-count herdr-term-max-connect-attempts)
    (should (herdr-term--gave-up-p))))

(ert-deftest herdr-term--update-mode-line:reports-state ()
  "The mode line distinguishes waiting, streaming and abandoned."
  (herdr-term-with-test-buffer
    (herdr-term--update-mode-line)
    (should (equal mode-line-process " herdr:w1:p1[ro …]"))
    (setq herdr-term--writable t
          herdr-term--last-seq 12)
    (herdr-term--update-mode-line)
    (should (equal mode-line-process " herdr:w1:p1[rw 12]"))
    (setq herdr-term--fail-count herdr-term-max-connect-attempts)
    (herdr-term--update-mode-line)
    (should (equal mode-line-process " herdr:w1:p1[rw dead]"))))

;;; Input

(ert-deftest herdr-term--send-input:wraps-bytes-in-json ()
  "Input reaches herdr as one base64 `terminal.input' line."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (herdr-term--send-input "ls\r")
    (should (eql (length herdr-term-test-sent) 1))
    (let ((line (car herdr-term-test-sent)))
      (should (string-suffix-p "\n" line))
      (let ((object (json-parse-string (string-trim-right line))))
        (should (equal (gethash "type" object) "terminal.input"))
        (should (equal (base64-decode-string (gethash "bytes" object))
                       "ls\r"))))))

(ert-deftest herdr-term--send-input:encodes-multibyte ()
  "A multibyte string becomes UTF-8 bytes before it is base64 encoded."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (herdr-term--send-input "é")
    (let* ((object (json-parse-string
                    (string-trim-right (car herdr-term-test-sent))))
           (bytes (base64-decode-string (gethash "bytes" object))))
      (should (equal bytes (encode-coding-string "é" 'utf-8)))
      (should (eql (length bytes) 2)))))

(ert-deftest herdr-term--send-input:refuses-read-only ()
  "An observe stream speaks no input, so nothing may be written to it."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable nil)
    (herdr-term--send-input "ls\r")
    (should (null herdr-term-test-sent))))

;;; Input Diversion

(defvar herdr-term-test-diverted nil
  "Strings handed to `herdr-term--send-input', most recent first.")

(defvar herdr-term-test-piped nil
  "Strings that reached the bridge process, most recent first.")

(defun herdr-term-test-await-pipe ()
  "Wait for the bridge to echo, up to a tenth of a second.
A diverted write never reaches the pipe and so never echoes, and there
the wait runs to its timeout and leaves the absence the test asserts."
  (let ((attempts 20))
    (while (and (null herdr-term-test-piped) (> attempts 0))
      (accept-process-output nil 0.005)
      (setq attempts (1- attempts)))))

(defun herdr-term-test-restore-advice (advised)
  "Put the divert back in the state ADVISED recorded before a test.
`advice-add' is idempotent, so re-adding an advice the test left in
place is a no-op, and only a test that removed it pays anything here."
  (if advised
      (advice-add 'process-send-string :around #'herdr-term--divert-input)
    (advice-remove 'process-send-string #'herdr-term--divert-input)))

(defmacro herdr-term-with-test-bridge (&rest body)
  "Evaluate BODY with `bridge', a tagged input bridge, and `buffer' bound.
The bridge is a real `cat', as the live one is, so that a write which
reaches the pipe comes back to the filter and is seen.  Nothing else
would tell a diverted write apart from one that was merely dropped.
BODY may read `herdr-term-test-diverted' and `herdr-term-test-piped'.

Whatever BODY does to the advice, the previous state is restored, so
that one test cannot decide whether the next one runs advised."
  (declare (indent 0) (debug t))
  `(let* ((buffer (generate-new-buffer " *herdr-term-bridge-test*"))
          (bridge (make-process
                   :name "herdr-term-bridge-test"
                   :buffer nil
                   :command '("cat")
                   :connection-type 'pipe
                   :coding 'binary
                   :noquery t
                   :filter (lambda (_process string)
                             (push string herdr-term-test-piped))))
          (advised (advice-member-p #'herdr-term--divert-input
                                    'process-send-string))
          (herdr-term-test-diverted nil)
          (herdr-term-test-piped nil))
     (process-put bridge 'herdr-term-input-buffer buffer)
     (unwind-protect
         (cl-letf (((symbol-function 'herdr-term--send-input)
                    (lambda (string) (push string herdr-term-test-diverted))))
           (with-current-buffer buffer ,@body))
       (herdr-term-test-restore-advice advised)
       (delete-process bridge)
       (kill-buffer buffer))))

(ert-deftest herdr-term--input-target:recognizes-only-a-bridge ()
  "A process speaks for a herdr buffer only once it is tagged with one."
  (herdr-term-with-test-bridge
    (should (eq (herdr-term--input-target bridge) buffer))
    (let ((stranger (make-pipe-process :name "herdr-term-stranger-test"
                                       :noquery t
                                       :filter #'ignore)))
      (unwind-protect
          (should-not (herdr-term--input-target stranger))
        (delete-process stranger)))
    (should-not (herdr-term--input-target nil))))

(ert-deftest herdr-term--input-target:forgets-a-dead-buffer ()
  "A bridge outliving its buffer stops claiming input for it."
  (herdr-term-with-test-bridge
    (let ((orphan (generate-new-buffer " *herdr-term-orphan-test*")))
      (process-put bridge 'herdr-term-input-buffer orphan)
      (kill-buffer orphan)
      (should-not (herdr-term--input-target bridge)))))

(ert-deftest herdr-term--divert-input:bypasses-the-bridge ()
  "A bridge write reaches herdr directly and never enters the pipe."
  (herdr-term-with-test-bridge
    (let ((sent nil))
      (herdr-term--divert-input (lambda (&rest args) (push args sent))
                                bridge "ls\r")
      (should (equal herdr-term-test-diverted '("ls\r")))
      (should (null sent)))))

(ert-deftest herdr-term--divert-input:diverts-into-the-owning-buffer ()
  "The forward runs in the bridge's buffer, not in whatever was current."
  (herdr-term-with-test-bridge
    (let ((seen nil))
      (cl-letf (((symbol-function 'herdr-term--send-input)
                 (lambda (_string) (setq seen (current-buffer)))))
        (with-temp-buffer
          (herdr-term--divert-input #'ignore bridge "x")))
      (should (eq seen buffer)))))

(ert-deftest herdr-term--divert-input:leaves-other-processes-alone ()
  "An untagged process keeps the sink `process-send-string' gave it."
  (herdr-term-with-test-bridge
    (let ((stranger (make-pipe-process :name "herdr-term-stranger-test"
                                       :noquery t
                                       :filter #'ignore))
          (sent nil))
      (unwind-protect
          (progn
            (herdr-term--divert-input
             (lambda (process string) (push (cons process string) sent))
             stranger "ls\r")
            (should (equal sent (list (cons stranger "ls\r"))))
            (should (null herdr-term-test-diverted)))
        (delete-process stranger)))))

(ert-deftest herdr-term--divert-input:reports-a-failed-send ()
  "A signal from the forward is demoted to a message, not raised.
ghostel discards any signal but `quit' that reaches its module, so
raising would lose the keystroke with nothing said anywhere."
  (herdr-term-with-test-bridge
    (let ((reported nil))
      (cl-letf (((symbol-function 'herdr-term--send-input)
                 (lambda (_string) (error "Stream is gone")))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq reported (apply #'format-message format args)))))
        (herdr-term--divert-input #'ignore bridge "x"))
      (should (string-match-p "Stream is gone" reported)))))

(ert-deftest herdr-term--divert-input:catches-a-real-send ()
  "Installed as advice, the divert intercepts an ordinary send call.
This is the property the module's own key encoder relies on: it writes
to `ghostel--process' with `process-send-string' and cannot be reached
any other way."
  (herdr-term-with-test-bridge
    ;; Unadvised first, so that the silent pipe below is evidence the
    ;; advice did something rather than evidence the pipe is deaf.  The
    ;; session may already be advised, so say so rather than assume it.
    (advice-remove 'process-send-string #'herdr-term--divert-input)
    (process-send-string bridge "\e[A")
    (herdr-term-test-await-pipe)
    (should (equal herdr-term-test-piped '("\e[A")))
    (should (null herdr-term-test-diverted))
    (setq herdr-term-test-piped nil)
    (advice-add 'process-send-string :around #'herdr-term--divert-input)
    (process-send-string bridge "\e[B")
    (herdr-term-test-await-pipe)
    (should (equal herdr-term-test-diverted '("\e[B")))
    (should (null herdr-term-test-piped))))

(ert-deftest herdr-term--ensure-input-bridge:tags-the-bridge-and-advises ()
  "Setting up a bridge tags it and installs the divert.
A second setup reuses the live bridge rather than forking another."
  (let ((buffer (generate-new-buffer " *herdr-term-setup-test*"))
        (advised (advice-member-p #'herdr-term--divert-input
                                  'process-send-string)))
    (unwind-protect
        (with-current-buffer buffer
          (setq herdr-term--pane "w1:p1")
          (herdr-term--ensure-input-bridge)
          (should (eq ghostel--process herdr-term--input-bridge))
          (should (eq (herdr-term--input-target herdr-term--input-bridge)
                      buffer))
          (should (advice-member-p #'herdr-term--divert-input
                                   'process-send-string))
          (let ((bridge herdr-term--input-bridge))
            (herdr-term--ensure-input-bridge)
            (should (eq herdr-term--input-bridge bridge))))
      (with-current-buffer buffer
        (herdr-term--kill-input-bridge))
      (herdr-term-test-restore-advice advised)
      (kill-buffer buffer))))

(ert-deftest herdr-term--ensure-input-bridge:tags-a-bridge-it-inherited ()
  "A bridge made before the divert existed is tagged all the same.
Reloading the library over a running session leaves exactly that: a live
bridge no advice ever saw, whose input would take the slow path forever."
  (let ((buffer (generate-new-buffer " *herdr-term-inherit-test*"))
        (advised (advice-member-p #'herdr-term--divert-input
                                  'process-send-string)))
    (unwind-protect
        (with-current-buffer buffer
          (setq herdr-term--pane "w1:p1"
                herdr-term--input-bridge
                (make-process :name "herdr-term-inherited-test"
                              :buffer nil
                              :command '("cat")
                              :connection-type 'pipe
                              :noquery t
                              :filter #'ignore))
          (should-not (herdr-term--input-target herdr-term--input-bridge))
          (herdr-term--ensure-input-bridge)
          (should (eq (herdr-term--input-target herdr-term--input-bridge)
                      buffer)))
      (with-current-buffer buffer
        (herdr-term--kill-input-bridge))
      (herdr-term-test-restore-advice advised)
      (kill-buffer buffer))))

(ert-deftest herdr-term--kill-input-bridge:retires-the-last-divert ()
  "The divert outlives one bridge and dies with the last of them.
Left installed, it would filter every `process-send-string' an Emacs
makes long after the last herdr buffer is gone."
  (skip-unless (not (herdr-term--input-bridge-live-p)))
  (let ((first (generate-new-buffer " *herdr-term-first-test*"))
        (second (generate-new-buffer " *herdr-term-second-test*"))
        (advised (advice-member-p #'herdr-term--divert-input
                                  'process-send-string)))
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (with-current-buffer buffer
              (setq herdr-term--pane "w1:p1")
              (herdr-term--ensure-input-bridge)))
          (with-current-buffer first
            (herdr-term--kill-input-bridge))
          (should (advice-member-p #'herdr-term--divert-input
                                   'process-send-string))
          (with-current-buffer second
            (herdr-term--kill-input-bridge))
          (should-not (advice-member-p #'herdr-term--divert-input
                                       'process-send-string)))
      (dolist (buffer (list first second))
        (with-current-buffer buffer
          (herdr-term--kill-input-bridge))
        (kill-buffer buffer))
      (herdr-term-test-restore-advice advised))))

;;; Scrolling

(ert-deftest herdr-term-scroll:sends-a-wheel-scroll ()
  "A scroll travels as `terminal.scroll', not as injected page keys."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (herdr-term-scroll-up)
    (let ((command (json-parse-string
                    (string-trim-right (car herdr-term-test-sent)))))
      (should (equal (gethash "type" command) "terminal.scroll"))
      (should (equal (gethash "direction" command) "up"))
      (should (equal (gethash "source" command) "wheel"))
      (should (eql (gethash "lines" command) herdr-term-scroll-lines)))))

(ert-deftest herdr-term-scroll:pages-by-a-screenful ()
  "A page keeps two rows, so consecutive pages overlap."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t
          herdr-term--rows 40)
    (herdr-term-scroll-page-down)
    (let ((command (json-parse-string
                    (string-trim-right (car herdr-term-test-sent)))))
      (should (equal (gethash "direction" command) "down"))
      (should (eql (gethash "lines" command) 38)))))

(ert-deftest herdr-term-scroll:bottom-stays-within-the-protocol ()
  "Returning to the end asks for more lines than any pane holds.
The count still has to fit the protocol's own `lines' field, which
herdr then clamps to the real bottom."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (herdr-term-scroll-to-bottom)
    (let ((command (json-parse-string
                    (string-trim-right (car herdr-term-test-sent)))))
      (should (equal (gethash "direction" command) "down"))
      (should (eql (gethash "lines" command) 65535)))))

(ert-deftest herdr-term-line-down:scrolls-only-at-the-last-line ()
  "Within the viewport a motion moves point; past it, the pane moves.
The buffer holds the viewport and nothing else, so there is no later
line for point to reach."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (let ((inhibit-read-only t))
      (insert "one\ntwo\nthree"))
    (goto-char (point-min))
    (herdr-term-line-down)
    (should (eql (line-number-at-pos) 2))
    (should (null herdr-term-test-sent))
    (goto-char (point-max))
    (herdr-term-line-down)
    (should (eql (line-number-at-pos) 3))
    (let ((command (json-parse-string
                    (string-trim-right (car herdr-term-test-sent)))))
      (should (equal (gethash "direction" command) "down"))
      (should (eql (gethash "lines" command) 1)))))

(ert-deftest herdr-term-line-up:scrolls-only-at-the-first-line ()
  "Point rises through the viewport, then the pane brings history down."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable t)
    (let ((inhibit-read-only t))
      (insert "one\ntwo\nthree"))
    (goto-char (point-max))
    (herdr-term-line-up)
    (should (null herdr-term-test-sent))
    (goto-char (point-min))
    (herdr-term-line-up)
    (let ((command (json-parse-string
                    (string-trim-right (car herdr-term-test-sent)))))
      (should (equal (gethash "direction" command) "up"))
      (should (eql (gethash "lines" command) 1)))))

(ert-deftest herdr-term-take-control:reconnects-with-control ()
  "Taking control switches the stream, which only a reconnect can do."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable nil)
    (herdr-term-take-control)
    (should herdr-term--writable)
    (should (eql herdr-term-test-streams 1))
    (should-error (herdr-term-take-control) :type 'user-error)))

(ert-deftest herdr-term-scroll:refuses-a-read-only-buffer ()
  "Scrolling is a control command, and an observer holds no control."
  (herdr-term-with-test-buffer
    (setq herdr-term--writable nil)
    (should-error (herdr-term-scroll-up) :type 'user-error)
    (should (null herdr-term-test-sent))))

;;; Panes

(ert-deftest herdr-term--panes:pairs-ids-with-info ()
  "Each pane is keyed by its own identifier."
  (cl-letf (((symbol-function 'herdr-api-request)
             (lambda (&rest _)
               (json-parse-string
                "{\"panes\":[{\"pane_id\":\"w1:p1\",\"cwd\":\"/tmp\"},\
{\"pane_id\":\"w2:p1\",\"cwd\":\"/var\"}]}"))))
    (let ((panes (herdr-term--panes)))
      (should (equal (mapcar #'car panes) '("w1:p1" "w2:p1")))
      (should (equal (gethash "cwd" (cdr (assoc "w2:p1" panes))) "/var")))))

(ert-deftest herdr-term--panes:tolerates-no-panes ()
  "A result carrying no panes is empty, not malformed."
  (cl-letf (((symbol-function 'herdr-api-request)
             (lambda (&rest _) (json-parse-string "{}"))))
    (should (null (herdr-term--panes)))))

(ert-deftest herdr-term--read-pane:reports-an-empty-session ()
  "No panes is an ordinary state herdr reports, not a failed call.
It deserves a message saying what to do, not an API error."
  (cl-letf (((symbol-function 'herdr-api-request)
             (lambda (&rest _) (json-parse-string "{}"))))
    (let ((error-data (should-error (herdr-term--read-pane "Pane: ")
                                    :type 'user-error)))
      (should-not (eq (car error-data) 'herdr-api-error))
      (should (string-match-p "No live herdr panes" (cadr error-data))))))

(ert-deftest herdr-term--sentinel:does-not-retry-a-pane-that-is-gone ()
  "A pane herdr no longer has is an ending, not a dropped stream.
Retried as a drop it failed three times over and left the buffer marked
dead, offering a resync that could never work."
  (let ((herdr-term-pane-gone-action 'keep))
    (herdr-term-with-test-buffer
      (setq herdr-term--last-seq 7
            herdr-term--close-reason
            "terminal attach ended: terminal term_abc not found")
      (herdr-term-test-end-stream herdr-term--process "finished\n")
      (should (zerop herdr-term-test-streams))
      (should-not (timerp herdr-term--reconnect-timer))
      (should herdr-term--pane-gone)
      (should (string-match-p "closed" mode-line-process)))))

(ert-deftest herdr-term--sentinel:kills-the-buffer-of-a-gone-pane ()
  "By default the buffer goes where the pane went.
The kill is deferred out of the sentinel rather than run inside it, so
what the test can see is the deferral."
  (let ((herdr-term-pane-gone-action 'kill)
        (deferred nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _repeat function &rest args)
                 (setq deferred (cons function args)))))
      (herdr-term-with-test-buffer
        (setq herdr-term--last-seq 7
              herdr-term--close-reason
              "terminal session control failed: terminal target w1:p1 not found")
        (herdr-term-test-end-stream herdr-term--process "finished\n")
        (should (equal deferred (list #'kill-buffer (current-buffer))))))))

(ert-deftest herdr-term--sentinel:keeps-the-buffer-when-told-to ()
  "Nothing is killed under `keep', however the pane ended.
The stream's input bridge still goes: kept alive it would hold a `cat'
and `ghostel--process' for the life of the buffer, with no stream left
for anything typed into it to reach."
  (let ((herdr-term-pane-gone-action 'keep)
        (deferred nil)
        (bridge (make-pipe-process :name "herdr-term-test-bridge"
                                   :noquery t
                                   :filter #'ignore)))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _repeat function &rest args)
                 (setq deferred (cons function args)))))
      (herdr-term-with-test-buffer
        (setq herdr-term--last-seq 7
              herdr-term--input-bridge bridge
              herdr-term--close-reason
              "terminal session control failed: terminal target w1:p1 not found")
        (herdr-term-test-end-stream herdr-term--process "finished\n")
        (should-not deferred)
        (should herdr-term--pane-gone)
        (should-not (process-live-p bridge))
        (should-not herdr-term--input-bridge)))))

(ert-deftest herdr-term--sentinel:says-nothing-about-a-pane-that-ended ()
  "Closing a workspace is not a fault and must reach no echo area.
Every pane of a workspace reports itself gone as it goes, so anything
said here arrives once per pane and buries whatever the user was
reading."
  (let ((herdr-term-pane-gone-action 'keep)
        (reported nil))
    (herdr-term-with-test-buffer
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format-message format args) reported))))
        (setq herdr-term--last-seq 7)
        (herdr-term-test-apply
         (json-serialize (list :type "terminal.closed"
                               :reason "terminal term_abc exited")))
        (herdr-term-test-end-stream herdr-term--process "finished\n"))
      (should herdr-term--pane-gone)
      (should (null reported)))))

(ert-deftest herdr-term--pane-gone-p:knows-what-herdr-actually-sends ()
  "Every reason herdr 0.7.5 gives for a pane that is not there.
The match is on the server's own wording, so a reason that gains a
suffix stops matching and the retry loop comes back.  These are the
literal strings, quoted from herdr's headless server, and a change to
any of them should fail here rather than in a pane weeks later."
  (dolist (reason '("terminal session control failed: terminal target w1:p1 not found"
                    "terminal attach failed: terminal term_abc not found"
                    "terminal attach ended: terminal term_abc not found"
                    "terminal term_abc exited"))
    (should (herdr-term--pane-gone-p reason)))
  ;; The near misses, which are all retryable.
  (dolist (reason '("terminal attach failed: terminal term_abc has a read in progress; retry"
                    "terminal attach taken over"
                    "server is shutting down"
                    "detached"))
    (should-not (herdr-term--pane-gone-p reason)))
  ;; The reason comes off the wire, so it need not be a string at all.
  (should-not (herdr-term--pane-gone-p 42))
  (should-not (herdr-term--pane-gone-p nil)))

(ert-deftest herdr-term--start-stream:clears-a-pane-reported-gone ()
  "A pane can come back under the same id, and a resync is how.
Left set, the flag outranks a live sequence number in the mode line and
a fully resynced buffer still reads closed."
  (let ((herdr-term-pane-gone-action 'keep)
        ;; The fixture replaces `herdr-term--start-stream' with a counter,
        ;; so the real one is held on to before entering it.
        (start-stream (symbol-function 'herdr-term--start-stream)))
    (herdr-term-with-test-buffer
      (setq herdr-term--last-seq 7
            herdr-term--close-reason
            "terminal attach ended: terminal term_abc not found")
      (herdr-term-test-end-stream herdr-term--process "finished\n")
      (should herdr-term--pane-gone)
      ;; Only the resets matter here, and they run before the connect
      ;; this buffer has no server for.
      (ignore-errors (funcall start-stream (current-buffer)))
      (should-not herdr-term--pane-gone)
      (should-not herdr-term--last-seq))))

(ert-deftest herdr-term--sentinel:still-reconnects-an-ordinary-drop ()
  "A stream that dropped for any other reason is still transient."
  (herdr-term-with-test-buffer
    (setq herdr-term--last-seq 7
          herdr-term--close-reason "server restarted")
    (herdr-term-test-end-stream herdr-term--process "finished\n")
    (should (= 1 herdr-term-test-streams))
    (should-not herdr-term--pane-gone)))

(ert-deftest herdr-term--note-resize:takes-the-window-a-local-hook-gets ()
  "A local hook is handed the window that changed, not the frame.
Read as a frame it reached `window-list' as one, which signals \"Window
is on a different frame\", so every resize errored and no pane was ever
fitted."
  (herdr-term-with-test-buffer
    (save-window-excursion
      (set-window-buffer (selected-window) (current-buffer))
      (herdr-term--note-resize (selected-window))
      (should (timerp herdr-term--resize-timer))
      (herdr-term--cancel-resize))))

;;; Evil Keys

(declare-function evil-local-mode "evil-core" (&optional arg))
(declare-function evil-change-state "evil-core" (state &optional message))
(declare-function evil-ghostel-mode "evil-ghostel" (&optional arg))

(defmacro herdr-term-with-evil-buffer (state &rest body)
  "Evaluate BODY in a herdr terminal buffer that evil is in STATE in.
Skip the test when evil is absent, which it may be: it is an
integration rather than a dependency of this package.  evil-ghostel is
loaded with it whenever it is installed, because a herdr buffer very
likely has it and it competes for the same keys."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (require 'evil nil t))
     (require 'evil-ghostel nil t)
     (with-temp-buffer
       (evil-local-mode 1)
       (when (fboundp 'evil-ghostel-mode)
         (evil-ghostel-mode 1))
       (herdr-term-command-mode 1)
       (evil-change-state ,state)
       ,@body)))

(ert-deftest herdr-term-command-mode:sends-escape-to-the-pane ()
  "Escape reaches the program in the pane rather than leaving insert.
evil spends it on `evil-normal-state', and evil-ghostel hands it over
only while ghostel reports an alternate screen, which a herdr pane
never does.  Outranking both is the whole point of binding it against
the minor mode."
  (herdr-term-with-evil-buffer 'insert
    (should (eq (key-binding (kbd "<escape>")) #'ghostel--send-event))))

(ert-deftest herdr-term-command-mode:keeps-normal-state-escape ()
  "Normal state has no program to feed, so escape stays evil's."
  (herdr-term-with-evil-buffer 'normal
    (should-not (eq (key-binding (kbd "<escape>")) #'ghostel--send-event))))

(ert-deftest herdr-term-command-mode:passes-editing-keys-through ()
  "Backspace and the shell's line editing keys reach the program.
evil and evil-ghostel both bind these in insert state, so a binding
that loses the rank contest takes the shell's line editing away."
  (herdr-term-with-evil-buffer 'insert
    (dolist (key herdr-term-evil-passthrough-keys)
      (should (eq (key-binding (kbd key)) #'ghostel--send-event)))))

(ert-deftest herdr-term-command-mode:scrolls-the-pane-in-normal-state ()
  "Normal state motions move the pane's viewport, not point.
The buffer only ever holds the viewport, so evil's own motions have
nothing to move onto."
  (herdr-term-with-evil-buffer 'normal
    (should (eq (key-binding "j") #'herdr-term-line-down))
    (should (eq (key-binding (kbd "C-u")) #'herdr-term-scroll-half-page-up))
    (should (eq (key-binding "G") #'herdr-term-scroll-to-bottom))))

;;; _
(provide 'herdr-term-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-term-tests.el ends here
