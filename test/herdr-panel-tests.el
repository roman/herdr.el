;;; herdr-panel-tests.el --- Tests for herdr-panel  -*- lexical-binding:t -*-

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

;;; Commentary:

;; herdr-panel declares the terminal's buffer-local variables rather than
;; requiring the terminal, because ghostel loads a native module and a
;; panel is meant to work without one.  A declared variable is special and
;; unbound until herdr-term defines it, and `buffer-local-value' signals on
;; exactly that, so every reader of one has to be guarded.  These tests
;; unbind the pair and run the readers, which is the state a session is in
;; until the first terminal opens.

;;; Code:

(require 'ert)

(require 'herdr-panel)

;;; Fixtures

(defmacro herdr-panel-without-terminal (&rest body)
  "Evaluate BODY as if herdr-term had never been loaded.
Both of the terminal's buffer-local variables go back to declared and
unbound, whatever this Emacs has loaded, and are restored afterwards."
  (declare (indent 0) (debug t))
  `(let ((pane (and (boundp 'herdr-term--pane)
                    (default-value 'herdr-term--pane)))
         (writable (and (boundp 'herdr-term--writable)
                        (default-value 'herdr-term--writable)))
         (bound (boundp 'herdr-term--pane)))
     (makunbound 'herdr-term--pane)
     (makunbound 'herdr-term--writable)
     (unwind-protect
         (progn ,@body)
       (when bound
         (setq-default herdr-term--pane pane)
         (setq-default herdr-term--writable writable)))))

(defmacro herdr-panel-with-buffer (name &rest body)
  "Evaluate BODY in a fresh buffer called NAME, killed afterwards."
  (declare (indent 1) (debug t))
  `(let ((buffer (generate-new-buffer ,name)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (kill-buffer buffer))))

;;; Reading A Buffer Without The Terminal

(ert-deftest herdr-panel--buffer-pane:answers-without-the-terminal ()
  "A buffer mirrors no pane when nothing can mirror one yet.
Signalling here takes down every panel redraw, because each one asks
which pane the selected window is showing before it draws a row."
  (herdr-panel-without-terminal
    (herdr-panel-with-buffer "*herdr-test*"
      (should (null (herdr-panel--buffer-pane buffer))))))

(ert-deftest herdr-panel-current-pane:answers-without-the-terminal ()
  "Nothing is current when no buffer can be."
  (herdr-panel-without-terminal
    (should (null (herdr-panel-current-pane)))))

(ert-deftest herdr-panel-open-panes:answers-without-the-terminal ()
  "No pane is open, rather than the question being unanswerable."
  (herdr-panel-without-terminal
    (should (null (herdr-panel-open-panes)))
    (should (null (herdr-panel-pane-open-p "w1:p1")))
    (should (null (herdr-panel-pane-writable-p "w1:p1")))))

(ert-deftest herdr-panel-own-buffer-p:answers-without-the-terminal ()
  "An unrelated buffer is not ours, and saying so must not signal.
`herdr-ui-quit' maps this over every buffer in the session, so one
that signals on `*scratch*' takes the command with it."
  (herdr-panel-without-terminal
    (herdr-panel-with-buffer "*herdr-test*"
      (should (null (herdr-panel-own-buffer-p buffer))))))

(ert-deftest herdr-panel-emphasis:recedes-without-the-terminal ()
  "A row with no buffer behind it is drawn as closed, not as an error."
  (herdr-panel-without-terminal
    (should (eq (herdr-panel-emphasis "w1:p1" nil) 'closed))
    (should (eq (herdr-panel-emphasis "w1:p1" "w1:p1") 'current))))

;;; Telling A Panel From A Terminal

(ert-deftest herdr-panel-own-buffer-p:counts-a-panel ()
  "A buffer with a refresh function is a panel whatever else it is."
  (herdr-panel-with-buffer "*herdr-test*"
    (setq-local herdr-panel-refresh-function #'ignore)
    (should (herdr-panel-own-buffer-p buffer))))

(ert-deftest herdr-panel-own-buffer-p:counts-a-terminal ()
  "A buffer mirroring a pane belongs to herdr without being a panel."
  (herdr-panel-with-buffer "*herdr-test*"
    (setq-local herdr-term--pane "w1:p1")
    (should (herdr-panel-own-buffer-p buffer))
    (should (null (buffer-local-value 'herdr-panel-refresh-function
                                      buffer)))))

;;; _
(provide 'herdr-panel-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-panel-tests.el ends here
