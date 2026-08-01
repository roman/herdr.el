;;; herdr-spike.el --- Spike: render a herdr pane in a ghostel buffer -*- lexical-binding: t; -*-

;; Throwaway spike for the herdr.el terminal plane.
;;
;; Goal: prove that a ghostel buffer can be a faithful, interactive view of a
;; pane the herdr *server* owns, using only the supported CLI bridges — no
;; binary client protocol.
;;
;;   output : `herdr terminal session observe|control <pane>' streams
;;            newline-JSON frames {"type":"terminal.frame","bytes":"<base64 ANSI>"}
;;            on stdout. We base64-decode `bytes' and feed the ANSI to the same
;;            libghostty-vt engine herdr renders with, via `ghostel--write-vt'.
;;   input  : `control' reads {"type":"terminal.input","text":...} on stdin.
;;
;; The buffer setup mirrors `ghostel-exec': enable `ghostel-mode', size the
;; terminal to the display window, `ghostel--init-buffer' (creates the term with
;; no process), then attach our herdr stream instead of a PTY.

(require 'ghostel)
(require 'json)

(defvar herdr-spike-binary (or (executable-find "herdr") "herdr")
  "Path to the herdr executable used by the spike.")

(defvar herdr-spike-force-redraw nil
  "When non-nil, force `ghostel--redraw-now' even during synchronized output.")

(defvar-local herdr-spike--proc nil "Frame-stream process for this buffer.")
(defvar-local herdr-spike--stdout "" "Partial stdout accumulator for line framing.")
(defvar-local herdr-spike--pane nil "herdr pane id mirrored by this buffer.")
(defvar-local herdr-spike--writable nil "Non-nil when the stream is `control' (input allowed).")

;;; Output: herdr frames -> ghostel

(defun herdr-spike--handle-frame (buffer obj)
  "Apply one decoded frame hash-table OBJ to BUFFER's ghostel terminal."
  (let ((type (gethash "type" obj)))
    (cond
     ((equal type "terminal.frame")
      (let ((b64 (gethash "bytes" obj)))
        (when b64
          (let ((bytes (base64-decode-string b64)))
            (with-current-buffer buffer
              (when ghostel--term
                (ghostel--write-vt ghostel--term bytes)
                (ghostel--redraw-now buffer herdr-spike-force-redraw)))))))
     ((equal type "terminal.closed")
      (with-current-buffer buffer
        (message "herdr-spike[%s]: closed (%s)"
                 herdr-spike--pane (gethash "reason" obj)))))))

(defun herdr-spike--filter (proc chunk)
  "Accumulate CHUNK, split complete newline-JSON lines, apply each frame."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq herdr-spike--stdout (concat herdr-spike--stdout chunk))
        (let* ((parts (split-string herdr-spike--stdout "\n"))
               (complete (butlast parts)))
          (setq herdr-spike--stdout (car (last parts)))
          (dolist (line complete)
            (unless (string-empty-p line)
              (let ((obj (ignore-errors (json-parse-string line))))
                (when (hash-table-p obj)
                  (herdr-spike--handle-frame buffer obj))))))))))

(defun herdr-spike--sentinel (proc event)
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (message "herdr-spike[%s]: %s" herdr-spike--pane (string-trim event))))))

;;; Input: keystrokes -> herdr control stdin

(defun herdr-spike--send-input (text)
  "Send TEXT to the pane as a control `terminal.input' command."
  (when (process-live-p herdr-spike--proc)
    (process-send-string
     herdr-spike--proc
     (concat (json-encode `(("type" . "terminal.input") ("text" . ,text))) "\n"))))

(defun herdr-spike-self-insert ()
  "Forward the pressed printable key to the pane."
  (interactive)
  (herdr-spike--send-input (string last-command-event)))

(defun herdr-spike--input-map ()
  "A keymap that forwards keys to the herdr control stream."
  (let ((map (make-sparse-keymap)))
    (dolist (ch (number-sequence ?\s ?~))
      (define-key map (vector ch) #'herdr-spike-self-insert))
    (define-key map (kbd "RET") (lambda () (interactive) (herdr-spike--send-input "\r")))
    (define-key map (kbd "TAB") (lambda () (interactive) (herdr-spike--send-input "\t")))
    (define-key map (kbd "DEL") (lambda () (interactive) (herdr-spike--send-input "\177")))
    (define-key map (kbd "<backspace>") (lambda () (interactive) (herdr-spike--send-input "\177")))
    (define-key map (kbd "C-c") (lambda () (interactive) (herdr-spike--send-input "\3")))
    (define-key map (kbd "ESC") (lambda () (interactive) (herdr-spike--send-input "\e")))
    map))

;;; Entry point

(defun herdr-spike-open (pane &optional writable)
  "Open a ghostel buffer mirroring herdr PANE.
With prefix arg WRITABLE, use `control' (keystrokes reach the pane);
otherwise `observe' (read-only, multiple viewers allowed)."
  (interactive "sPane id: \nP")
  (ghostel--load-module t)
  (let* ((name (format "*herdr:%s*" pane))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (ghostel-mode))
    (pop-to-buffer buffer (append display-buffer--same-window-action
                                  '((category . comint))))
    (let* ((window (get-buffer-window buffer t))
           (height (if window
                       (max 1 (with-selected-window window (floor (window-screen-lines))))
                     24))
           (width (if window (max 1 (window-max-chars-per-line window)) 80))
           (sub (if writable "control" "observe")))
      (with-current-buffer buffer
        (ghostel--init-buffer buffer height width)
        (setq herdr-spike--pane pane
              herdr-spike--writable writable
              herdr-spike--stdout "")
        (when writable
          (use-local-map (herdr-spike--input-map)))
        (let ((proc (make-process
                     :name (format "herdr-spike:%s" pane)
                     :buffer buffer
                     :command (list herdr-spike-binary "terminal" "session" sub pane
                                    "--rows" (number-to-string height)
                                    "--cols" (number-to-string width))
                     :connection-type 'pipe
                     :coding 'binary
                     :noquery t
                     :filter #'herdr-spike--filter
                     :sentinel #'herdr-spike--sentinel)))
          (setq herdr-spike--proc proc)))
      buffer)))

(defun herdr-spike-close ()
  "Kill the spike stream and buffer for the current buffer."
  (interactive)
  (when (process-live-p herdr-spike--proc)
    (delete-process herdr-spike--proc))
  (kill-buffer (current-buffer)))

(provide 'herdr-spike)
;;; herdr-spike.el ends here
