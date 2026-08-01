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

(defun herdr-term-test-apply (line)
  "Apply the message on LINE to the current buffer, as the filter would."
  (herdr-term--apply-message
   (current-buffer)
   (json-parse-string line :false-object nil :null-object nil)))

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

;;; _
(provide 'herdr-term-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-term-tests.el ends here
