;;; herdr-term.el --- A ghostel buffer mirroring a herdr-owned pane -*- lexical-binding: t; -*-

;; Renders a pane owned by the herdr server into a ghostel buffer, driven by the
;; `herdr terminal session observe|control' CLI bridges. Both ends run
;; libghostty-vt, so content and style render with full fidelity.
;;
;; Frame protocol (see docs/baseline.md). The stream is newline-JSON:
;;
;;   {"type":"terminal.frame","seq":N,"full":BOOL,"width":W,"height":H,
;;    "bytes":"<base64 ANSI>"}
;;   {"type":"terminal.closed","reason":...}
;;
;; herdr sends one `full:true' repaint on connect (the authoritative resync
;; point), then `full:false' deltas relative to the previous composed frame,
;; each with an incrementing `seq'. A client that drops or misorders a delta
;; diverges permanently, and there is no "request full frame" command — so the
;; only resync is to reconnect, which always begins with a fresh full frame.
;; This module therefore:
;;
;;   - treats a full frame as a hard reset (resize to the frame, then paint),
;;   - refuses a delta before the first full frame,
;;   - reconnects on any `seq' gap or unexpected stream exit.

;;; Code:

(require 'ghostel)
(require 'json)

(defvar herdr-term-binary (or (executable-find "herdr") "herdr")
  "Path to the herdr executable.")

(defvar herdr-term-reconnect-min-interval 0.4
  "Minimum seconds between automatic reconnects, to avoid reconnect storms.")

(defvar herdr-term-max-connect-attempts 3
  "How many times to retry a stream that exits without ever syncing.
Guards against looping forever on an invalid or vanished pane target.")

;; Buffer-local session state.
(defvar-local herdr-term--proc nil "Frame-stream process.")
(defvar-local herdr-term--stdout "" "Partial-line accumulator for stdout framing.")
(defvar-local herdr-term--pane nil "herdr pane id this buffer mirrors.")
(defvar-local herdr-term--writable nil "Non-nil when the stream is `control' (input allowed).")
(defvar-local herdr-term--last-seq nil "Last applied frame `seq', or nil before the first full frame.")
(defvar-local herdr-term--rows nil "Current terminal rows.")
(defvar-local herdr-term--cols nil "Current terminal cols.")
(defvar-local herdr-term--last-reconnect nil "`float-time' of the last automatic reconnect.")
(defvar-local herdr-term--synced nil "Non-nil once the current connection applied a full frame.")
(defvar-local herdr-term--fail-count 0 "Consecutive connections that exited without ever syncing.")
(defvar-local herdr-term--close-reason nil "Reason from the last `terminal.closed', for diagnostics.")
(defvar-local herdr-term--dead nil "Non-nil after giving up; a manual resync clears it.")
(defvar-local herdr-term--input-bridge nil "Process bridging ghostel's PTY writes to the control stream.")

;;; Frame application

(defun herdr-term--maybe-resize (rows cols)
  "Resize this buffer's ghostel terminal to ROWS x COLS when it changed.
The frame's dimensions are authoritative: applying a repaint sized for a
different grid would place cells outside it."
  (when (and rows cols
             (or (not (eql rows herdr-term--rows))
                 (not (eql cols herdr-term--cols))))
    (ghostel--set-size-with-cell-dims ghostel--term (max 1 rows) (max 1 cols))
    (setq herdr-term--rows rows
          herdr-term--cols cols)))

(defun herdr-term--paint (bytes)
  "Feed BYTES to the ghostel VT and repaint."
  (ghostel--write-vt ghostel--term bytes)
  ;; Force redraw: herdr wraps frames in synchronized output (mode 2026); an
  ;; unforced redraw would defer and leave us a frame behind.
  (ghostel--redraw-now (current-buffer) t))

(defun herdr-term--reset-term (rows cols)
  "Recreate this buffer's ghostel terminal at ROWS x COLS.
A full frame is authoritative, so it must land on a clean grid — the same
fresh handle `ghostel--init-buffer' gives a new buffer. Writing a full
frame onto a *reused* grid does not reset state (scroll region, saved
cursor, an alt-screen save left by an app herdr flattened away), so a grid
that drifted from herdr's would stay wrong. Recreating guarantees parity."
  (let ((r (max 1 (or rows herdr-term--rows 24)))
        (c (max 1 (or cols herdr-term--cols 80))))
    (ghostel--init-buffer (current-buffer) r c)
    (setq herdr-term--rows r
          herdr-term--cols c)
    ;; `ghostel--init-buffer' reset `ghostel--process' to nil; re-point the bridge.
    (when herdr-term--writable (herdr-term--ensure-input-bridge))))

(defun herdr-term--apply-frame (buffer obj)
  "Apply one decoded frame hash-table OBJ to BUFFER.
Return the symbol `resync' when this frame triggered a reconnect, so the
caller can stop feeding it the now-stale remainder of the same chunk."
  (with-current-buffer buffer
    (let ((type (gethash "type" obj)))
      (cond
       ((equal type "terminal.frame")
        (let ((seq (gethash "seq" obj))
              (full (gethash "full" obj))
              (rows (gethash "height" obj))
              (cols (gethash "width" obj))
              (b64 (gethash "bytes" obj)))
          (prog1
              (cond
               ((null b64)
                (herdr-term--resync "frame without bytes") 'resync)
               (full
                ;; A full frame is authoritative; if applying it fails, the
                ;; grid is in an unknown state — reconnect for a clean one.
                (condition-case err
                    (progn (herdr-term--reset-term rows cols)
                           (herdr-term--paint (base64-decode-string b64))
                           (setq herdr-term--last-seq seq
                                 herdr-term--synced t
                                 herdr-term--fail-count 0
                                 herdr-term--dead nil)
                           nil)
                  (error (herdr-term--resync (format "full apply failed: %S" err))
                         'resync)))
               ((null herdr-term--last-seq)
                (herdr-term--resync "delta before initial full frame") 'resync)
               ((/= seq (1+ herdr-term--last-seq))
                (herdr-term--resync (format "seq gap %s->%s" herdr-term--last-seq seq))
                'resync)
               (t
                ;; A delta assumes the prior grid; a malformed one desyncs, so
                ;; recover the same way as a gap.
                (condition-case err
                    (progn (herdr-term--maybe-resize rows cols)
                           (herdr-term--paint (base64-decode-string b64))
                           (setq herdr-term--last-seq seq)
                           nil)
                  (error (herdr-term--resync (format "delta apply failed: %S" err))
                         'resync))))
            (herdr-term--update-mode-line))))
       ((equal type "terminal.closed")
        ;; Leave `herdr-term--last-seq' intact: the sentinel owns recovery when
        ;; the process exits. Nulling it here would strand a still-live stream
        ;; on "delta before initial full frame" for every later delta.
        (setq herdr-term--close-reason (gethash "reason" obj))
        (message "herdr-term[%s]: stream closed (%s)"
                 herdr-term--pane (gethash "reason" obj))
        nil)))))

;;; Stream lifecycle

(defun herdr-term--filter (proc chunk)
  "Accumulate CHUNK, apply each complete newline-JSON frame."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq herdr-term--stdout (concat herdr-term--stdout chunk))
        (let* ((parts (split-string herdr-term--stdout "\n"))
               (complete (butlast parts)))
          (setq herdr-term--stdout (car (last parts)))
          ;; A resync mid-chunk kills this stream; the rest of `complete' is
          ;; from the dead stream and must not be applied to the new grid.
          (catch 'herdr-term--resynced
            (dolist (line complete)
              (unless (string-empty-p line)
                (let ((obj (ignore-errors
                             (json-parse-string line :false-object nil :null-object nil))))
                  (when (and (hash-table-p obj)
                             (eq 'resync (herdr-term--apply-frame buffer obj)))
                    (throw 'herdr-term--resynced nil)))))))))))

(defun herdr-term--sentinel (proc event)
  "Recover when the stream drops.
Intentional teardowns detach this sentinel first (see `herdr-term--kill-proc'),
so reaching here always means herdr closed the stream on us. A stream that had
synced is reconnected as a transient drop; one that exits without ever syncing
is retried a bounded number of times, then abandoned — otherwise an invalid or
vanished pane target loops forever."
  (let ((buffer (process-buffer proc)))
    (when (and (buffer-live-p buffer)
               (memq (process-status proc) '(exit signal)))
      (with-current-buffer buffer
        (let ((detail (or herdr-term--close-reason (string-trim event))))
          (cond
           (herdr-term--synced
            (message "herdr-term[%s]: stream exited (%s); reconnecting"
                     herdr-term--pane detail)
            (herdr-term--start-stream buffer))
           ((progn (setq herdr-term--fail-count (1+ herdr-term--fail-count))
                   (>= herdr-term--fail-count herdr-term-max-connect-attempts))
            (setq herdr-term--dead t)
            (message "herdr-term[%s]: giving up after %d attempts (%s); C-c C-l to retry"
                     herdr-term--pane herdr-term--fail-count detail))
           (t
            (message "herdr-term[%s]: connect failed (%s); retry %d/%d"
                     herdr-term--pane detail
                     herdr-term--fail-count herdr-term-max-connect-attempts)
            (herdr-term--start-stream buffer))))))))

(defun herdr-term--kill-proc ()
  "Delete this buffer's stream process without triggering the sentinel.
Detaching the sentinel and filter first is what makes an intentional kill
distinguishable from herdr dropping the stream — otherwise the sentinel
fires after teardown and races a spurious reconnect against ours."
  (when (process-live-p herdr-term--proc)
    (set-process-sentinel herdr-term--proc #'ignore)
    (set-process-filter herdr-term--proc #'ignore)
    (delete-process herdr-term--proc)))

(defun herdr-term--start-stream (buffer)
  "Kill any existing stream and start a fresh observe/control process for BUFFER.
A fresh connect always begins with a full frame, so this doubles as resync."
  (with-current-buffer buffer
    (herdr-term--kill-proc)
    (setq herdr-term--last-seq nil
          herdr-term--stdout ""
          herdr-term--synced nil)
    (let* ((sub (if herdr-term--writable "control" "observe"))
           ;; `control' without `--takeover' immediately detaches (sends one
           ;; `terminal.closed' with reason "detached" and no frames). We are the
           ;; legitimate owner reconnecting our own session, so always take over.
           (args (append (list "terminal" "session" sub herdr-term--pane
                               "--rows" (number-to-string (or herdr-term--rows 24))
                               "--cols" (number-to-string (or herdr-term--cols 80)))
                         (when herdr-term--writable (list "--takeover"))))
           (proc (make-process
                  :name (format "herdr-term:%s" herdr-term--pane)
                  :buffer buffer
                  :command (cons herdr-term-binary args)
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter #'herdr-term--filter
                  :sentinel #'herdr-term--sentinel)))
      (setq herdr-term--proc proc)
      (herdr-term--update-mode-line)
      proc)))

(defun herdr-term--resync (reason)
  "Reconnect the stream to recover a fresh full frame, debounced.
REASON is logged."
  (let ((now (float-time)))
    (if (and herdr-term--last-reconnect
             (< (- now herdr-term--last-reconnect) herdr-term-reconnect-min-interval))
        (message "herdr-term[%s]: resync suppressed (%s); too soon"
                 herdr-term--pane reason)
      (setq herdr-term--last-reconnect now)
      (message "herdr-term[%s]: resync (%s)" herdr-term--pane reason)
      (herdr-term--start-stream (current-buffer)))))

(defun herdr-term-resync ()
  "Force a full-frame resync of the current buffer.
Also clears a prior give-up so an abandoned stream can be retried."
  (interactive)
  (setq herdr-term--last-reconnect nil
        herdr-term--fail-count 0
        herdr-term--dead nil)
  (herdr-term--resync "manual"))

;;; Input: bridge ghostel's PTY sink to the herdr control stream

;; ghostel drives input the way any terminal does: its handlers and the module
;; key encoder write bytes to the terminal's PTY. With no native PTY that sink is
;; the buffer-local `ghostel--process'. We set it to a `cat' process and forward
;; whatever ghostel writes to it on to herdr's control stream. Bridging the sink
;; — rather than advising one send function, or re-binding keys — is what makes
;; every path work alike: printable keys, evil-ghostel passthrough, and the
;; encoder-based keys (backspace, arrows, function keys) that write straight to
;; the PTY inside the module. It also satisfies ghostel's own live-process checks.

;; Older versions advised `ghostel--write-pty'; drop that on reload so it cannot
;; dangle once the advice function is gone.
(when (fboundp 'ghostel--write-pty)
  (ignore-errors (advice-remove 'ghostel--write-pty 'herdr-term--pty-redirect)))

(defun herdr-term--send-raw (bytes)
  "Forward raw terminal input BYTES to the control stream as `terminal.input'."
  (when (process-live-p herdr-term--proc)
    (let ((unibyte (if (multibyte-string-p bytes)
                       (encode-coding-string bytes 'utf-8)
                     bytes)))
      (process-send-string
       herdr-term--proc
       (concat (json-encode (list (cons "type" "terminal.input")
                                  (cons "bytes" (base64-encode-string unibyte t))))
               "\n")))))

(defun herdr-term--ensure-input-bridge ()
  "Point `ghostel--process' at a live bridge forwarding input to the stream.
Idempotent: reuses the bridge, recreating it only if it died. Must run after
every `ghostel--init-buffer', which resets `ghostel--process' to nil."
  (unless (process-live-p herdr-term--input-bridge)
    (let ((buffer (current-buffer)))
      (setq herdr-term--input-bridge
            (make-process
             :name (format "herdr-term-input:%s" herdr-term--pane)
             :command '("cat")
             :connection-type 'pipe
             :coding 'binary
             :noquery t
             :filter (lambda (_proc bytes)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (herdr-term--send-raw bytes))))))))
  (setq ghostel--process herdr-term--input-bridge))

;;; Client-local command keys

(defvar herdr-term-command-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-l") #'herdr-term-resync)
    (define-key map (kbd "C-c C-k") #'herdr-term-close)
    map)
  "Keymap for `herdr-term-command-mode'.")

(define-minor-mode herdr-term-command-mode
  "Client-local commands (resync, close) for a herdr terminal buffer."
  :interactive nil)

;;; Presentation

(defun herdr-term--update-mode-line ()
  (setq mode-line-process
        (format " herdr:%s[%s%s]"
                herdr-term--pane
                (if herdr-term--writable "rw" "ro")
                (if herdr-term--last-seq (format " %d" herdr-term--last-seq) " …")))
  (force-mode-line-update))

;;; Talking to the herdr server (control plane, via the CLI)

(defun herdr-term--run-json (&rest args)
  "Run herdr with ARGS, parse stdout as JSON, return the hash-table or nil.
Stderr is discarded so warnings cannot corrupt the parse."
  (with-temp-buffer
    (let ((status (apply #'call-process herdr-term-binary nil (list t nil) nil args)))
      (when (eq status 0)
        (goto-char (point-min))
        (ignore-errors (json-parse-buffer :false-object nil :null-object nil))))))

(defun herdr-term--result (resp)
  "Return the `result' object of a herdr JSON RESP, or nil."
  (and (hash-table-p resp) (gethash "result" resp)))

(defun herdr-term--live-panes ()
  "Return an alist of (PANE-ID . INFO-HASH) for live herdr panes."
  (let* ((result (herdr-term--result (herdr-term--run-json "pane" "list")))
         (panes (and result (gethash "panes" result))))
    (mapcar (lambda (p) (cons (gethash "pane_id" p) p))
            (append (or panes []) nil))))

(defun herdr-term--read-pane (prompt)
  "Read a live herdr pane id with completion, annotated by cwd and agent."
  (let ((panes (herdr-term--live-panes)))
    (unless panes
      (user-error "No live herdr panes; create one with M-x herdr-term-new"))
    (let* ((annotate
            (lambda (id)
              (let ((p (cdr (assoc id panes))))
                (when p
                  (concat "  " (or (gethash "cwd" p) "")
                          (let ((a (gethash "agent" p))) (if a (format " (%s)" a) ""))
                          (let ((w (gethash "workspace_id" p))) (if w (format " [%s]" w) "")))))))
           (completion-extra-properties (list :annotation-function annotate)))
      (completing-read prompt (mapcar #'car panes) nil t))))

;;; Entry / teardown

;;;###autoload
(defun herdr-term-open (pane &optional writable)
  "Open a ghostel buffer mirroring herdr PANE.
With prefix arg WRITABLE, use `control' so keystrokes reach the pane;
otherwise `observe' (read-only)."
  (interactive (list (herdr-term--read-pane "Open pane: ") current-prefix-arg))
  (ghostel--load-module t)
  (let* ((name (format "*herdr:%s*" pane))
         (existing (get-buffer name)))
    ;; Re-opening a pane that is already streaming just shows it; re-initializing
    ;; a live buffer would tear down and rebuild a working terminal.
    (if (and existing (process-live-p (buffer-local-value 'herdr-term--proc existing)))
        (pop-to-buffer existing)
      (let ((buffer (get-buffer-create name)))
        (with-current-buffer buffer
          (ghostel-mode))
        (pop-to-buffer buffer (append display-buffer--same-window-action
                                      '((category . comint))))
        (let* ((window (get-buffer-window buffer t))
               (rows (if window (max 1 (with-selected-window window (floor (window-screen-lines)))) 24))
               (cols (if window (max 1 (window-max-chars-per-line window)) 80)))
          (with-current-buffer buffer
            ;; Size to the window so the spawn requests a sensible grid; the
            ;; first full frame re-inits to herdr's authoritative dimensions.
            (ghostel--init-buffer buffer rows cols)
            (setq herdr-term--pane pane
                  herdr-term--writable writable
                  herdr-term--rows rows
                  herdr-term--cols cols
                  herdr-term--last-seq nil
                  herdr-term--last-reconnect nil)
            ;; Input flows through the ghostel PTY bridge, so ghostel and
            ;; evil-ghostel drive keys natively. Only the client-local command
            ;; keys need a (resync-surviving) minor-mode map.
            (herdr-term-command-mode 1)
            (when writable (herdr-term--ensure-input-bridge))
            (add-hook 'kill-buffer-hook #'herdr-term--on-kill nil t)
            (herdr-term--start-stream buffer))
          buffer)))))

;;;###autoload
(defun herdr-term-new (&optional cwd)
  "Create a new herdr terminal and open it writable in Emacs.
Creates a fresh herdr workspace whose root pane runs a shell, then attaches
a control stream so you can type into it — this is how you drive a terminal
from Emacs. With a prefix arg, prompt for the working directory; otherwise
use `default-directory' (falling back to home for a remote buffer)."
  (interactive (list (when current-prefix-arg
                       (read-directory-name "New terminal cwd: "))))
  (let* ((dir (expand-file-name
               (or cwd (if (file-remote-p default-directory) "~" default-directory))))
         (result (herdr-term--result
                  (herdr-term--run-json "workspace" "create" "--cwd" dir)))
         (root (and result (gethash "root_pane" result)))
         (pane (and root (gethash "pane_id" root))))
    (if pane
        (herdr-term-open pane t)
      (user-error "herdr: could not create a terminal"))))

(defun herdr-term--on-kill ()
  "Tear down the stream and input bridge when the buffer is killed."
  (herdr-term--kill-proc)
  (when (process-live-p herdr-term--input-bridge)
    (delete-process herdr-term--input-bridge)))

(defun herdr-term-close ()
  "Kill this buffer's stream and buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(provide 'herdr-term)
;;; herdr-term.el ends here
