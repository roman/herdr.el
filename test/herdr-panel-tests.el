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

;; The rest is what the panels share when a row is named rather than
;; walked to: the one line a row is offered as, and the table it is
;; offered in.  `herdr-panel-tests-choosing' stands in for the completion
;; framework, and every panel's own suite uses it.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-panel)

;;; Fixtures

(defvar herdr-panel-tests--offered nil
  "What the last stubbed `completing-read' was offered, in order.")

(defmacro herdr-panel-tests-offline (&rest body)
  "Evaluate BODY with a reader asking for no session.
Every reader makes sure of a tree before it builds its rows, and there
is no server here to answer for one."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'herdr-panel-ensure-session) #'ignore))
     ,@body))

(defmacro herdr-panel-tests-choosing (nth &rest body)
  "Evaluate BODY with `completing-read' picking candidate NTH.
`herdr-panel-tests--offered' is left holding what it was offered, in
the order it was offered, so that a test can assert on the order as
well as on the choice."
  (declare (indent 1) (debug t))
  `(let ((herdr-panel-tests--offered nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt collection &rest _)
                  (setq herdr-panel-tests--offered
                        (mapcar #'substring-no-properties
                                (all-completions "" collection)))
                  (nth ,nth herdr-panel-tests--offered))))
       ,@body)))

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

;;; Drawing A Row On One Line

(ert-deftest herdr-panel-entry-line:brings-the-detail-up-onto-the-line ()
  "What a panel puts under a name follows it in a candidate.
A candidate is one line, and the directory under a workspace is a
large part of what a reader types to pick one of two checkouts."
  (should (equal (substring-no-properties
                  (herdr-panel-entry-line
                   '(:status "idle" :label "herdr"
                     :detail ("~/Projects/oss/herdr.el" "master"))))
                 "○ herdr  ~/Projects/oss/herdr.el  master")))

(ert-deftest herdr-panel-entry-line:draws-a-row-that-has-only-a-name ()
  "An entry with nothing under it is the name and nothing else."
  (should (equal (substring-no-properties
                  (herdr-panel-entry-line '(:status "blocked" :label "herdr")))
                 "● herdr"))
  (should (equal (substring-no-properties
                  (herdr-panel-entry-line
                   '(:status "blocked" :label "herdr" :detail (nil ""))))
                 "● herdr")))

(ert-deftest herdr-panel-entry-line:keeps-the-mark-and-the-aside ()
  "The status mark and the kind of agent both survive the flattening.
The mark is what a reader scans for, and it is the one field a panel
colours by status."
  (should (equal (substring-no-properties
                  (herdr-panel-entry-line
                   '(:status "working" :label "herdr" :aside "✳"
                     :detail "running tests")))
                 "● herdr ✳  running tests")))

;;; Telling Two Rows Apart

(ert-deftest herdr-panel--distinct:names-every-repeat-by-its-pane ()
  "Two rows that draw alike must not both lead to the first pane.
Two agents of one kind, in one window, reporting the same title, draw
the same line; the pane is the one thing about them that cannot
repeat.  Both are named, because a line singled out among identical
ones reads as the odd one rather than as one of a pair."
  (let ((rows (herdr-panel--distinct '(("● herdr ✳" . "w1:p1")
                                       ("● herdr ✳" . "w1:p2")))))
    (should (equal (mapcar #'cdr rows) '("w1:p1" "w1:p2")))
    (should (equal (mapcar (lambda (row) (substring-no-properties (car row)))
                           rows)
                   '("● herdr ✳ w1:p1" "● herdr ✳ w1:p2")))))

(ert-deftest herdr-panel--distinct:leaves-rows-that-differ-alone ()
  "Nothing is added to a line that was already its own."
  (let ((rows '(("● a" . "w1:p1") ("● b" . "w1:p2"))))
    (should (equal (herdr-panel--distinct rows) rows))))

;;; Offering The Rows

(ert-deftest herdr-panel-read-pane:answers-with-the-pane-behind-the-line ()
  "A reader picks a line and gets the pane it stands for."
  (herdr-panel-tests-choosing 1
    (should (equal (herdr-panel-read-pane "Agent: " '(("● a" . "w1:p1")
                                                      ("● b" . "w1:p2")))
                   "w1:p2"))))

(ert-deftest herdr-panel-read-pane:refuses-a-prompt-answered-with-nothing ()
  "An empty answer is not a row, whatever `completing-read' allows.
It lets the empty string out however much a match is required, and a
nil pane carried on with reaches the terminal as an attach to nowhere."
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
    (should-error (herdr-panel-read-pane "Agent: " '(("● a" . "w1:p1")))
                  :type 'user-error)))

(ert-deftest herdr-panel--table:says-not-to-sort-what-it-holds ()
  "The table asks the framework itself not to reorder the candidates."
  (let ((metadata (cdr (funcall (herdr-panel--table nil) "" nil 'metadata))))
    (should (eq (cdr (assq 'display-sort-function metadata)) #'identity))
    (should (eq (cdr (assq 'cycle-sort-function metadata)) #'identity))))

(ert-deftest herdr-panel--table:completes-a-name-past-the-status-mark ()
  "A row opens with its mark, which no prefix style can see past.
`basic' is what Emacs completes with until told otherwise, so without
an entry for the category typing a workspace's name would match
nothing at all.  The second half is the state this guards against."
  (let ((table (herdr-panel--table '(("● herdr  ~/Projects" . "w1:p1"))))
        (completion-styles '(basic partial-completion emacs22))
        (completion-category-overrides nil))
    (should (completion-all-completions "herdr" table nil 5))
    (should-not (let ((completion-category-defaults nil))
                  (completion-all-completions "herdr" table nil 5)))))

;;; Choosing How To Open

(ert-deftest herdr-panel-access:inverts-on-a-prefix-argument ()
  "Naming a row and pressing RET on it must land the same way.
Both ask here, so the prefix argument means one thing in both."
  (let ((herdr-panel-visit-access 'control))
    (should (eq (herdr-panel-access nil) 'control))
    (should (eq (herdr-panel-access t) 'observe)))
  (let ((herdr-panel-visit-access 'observe))
    (should (eq (herdr-panel-access nil) 'observe))
    (should (eq (herdr-panel-access t) 'control))))

;;; _
(provide 'herdr-panel-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-panel-tests.el ends here
