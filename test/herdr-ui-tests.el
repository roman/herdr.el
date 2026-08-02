;;; herdr-ui-tests.el --- Tests for herdr-ui  -*- lexical-binding:t -*-

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

;; The column is a list of panels and the weight each takes of it, and an
;; entry may name a panel from a file that is not loaded.  What is worth
;; testing is the arithmetic that turns weights into shares, and that an
;; optional panel costs nothing while its file is absent.

;; Windows are never made: `herdr-ui--display' is replaced, so a test says
;; what the layout would be rather than building one on a batch frame.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-ui)

;;; Fixtures

(defvar herdr-ui-tests--shown nil
  "What `herdr-ui--display' was asked to show, in order.
Each entry has the form (BUFFER-NAME SLOT . HEIGHT).")

(defmacro herdr-ui-with-layout (&rest body)
  "Evaluate BODY with the column empty and no windows made.
`herdr-ui-tests--shown' collects what the layout asked for.
`herdr-ui-panels' is restored afterwards, so a test cannot leak a
panel into the next one."
  (declare (indent 0) (debug t))
  `(let ((herdr-ui-panels nil)
         (herdr-ui-tests--shown nil))
     (cl-letf (((symbol-function 'herdr-ui--display)
                (lambda (buffer slot height)
                  ;; Appended rather than pushed, so that a test reading
                  ;; the list mid-body reads it top of column first.
                  (setq herdr-ui-tests--shown
                        (append herdr-ui-tests--shown
                                (list (cons (buffer-name buffer)
                                            (cons slot height)))))
                  buffer)))
       ,@body)))

(defun herdr-ui-tests--panel (name)
  "Return a function standing in for a panel whose buffer is called NAME."
  (lambda () (get-buffer-create name)))

;;; Leaving Out A Panel That Is Not Loaded

(ert-deftest herdr-ui--show-panels:skips-an-undefined-panel ()
  "An entry naming a file that is not loaded is passed over.
This is what lets an optional panel keep its place in the order at no
cost: `herdr-tuicr' is not loaded with the rest of herdr, and the
layout must stand without it rather than signal."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 1)
                            (herdr-ui-tests--panel-that-is-not-defined . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'car herdr-ui-tests--shown) '("spaces")))))

(ert-deftest herdr-ui--show-panels:shares-out-what-a-missing-panel-left ()
  "The panels that are there divide the whole column between them.
A skipped entry must not leave a gap, or an uninstalled optional panel
would cost room for nothing."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 3)
                            (,(herdr-ui-tests--panel "agents") . 2)
                            (herdr-ui-tests--panel-that-is-not-defined . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cddr herdr-ui-tests--shown)
                   (list (/ 3.0 5) (/ 2.0 5))))))

;;; Sharing The Column

(ert-deftest herdr-ui--show-panels:divides-the-column-by-weight ()
  "Weights are shares of their own total, not fractions of the frame.
That is what lets a panel be added without every other weight having to
be rewritten."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 3)
                            (,(herdr-ui-tests--panel "agents") . 2)
                            (,(herdr-ui-tests--panel "reviews") . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cddr herdr-ui-tests--shown)
                   (list (/ 3.0 6) (/ 2.0 6) (/ 1.0 6))))))

(ert-deftest herdr-ui--show-panels:stacks-in-order ()
  "Slots increase down the column, so the first entry is the top one."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 1)
                            (,(herdr-ui-tests--panel "agents") . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cadr herdr-ui-tests--shown) '(0 1)))))

(ert-deftest herdr-ui--show-panels:shows-nothing-when-there-is-nothing ()
  "An empty column is empty rather than a division by zero."
  (herdr-ui-with-layout
    (herdr-ui--show-panels)
    (should (null herdr-ui-tests--shown))))

;;; Quitting

(ert-deftest herdr-ui-quit:kills-panels-and-spares-terminals ()
  "Quitting takes down the furniture, not the work.
A panel left alive would go on asking a stopped session to redraw it,
while a terminal mirroring a pane is what the user was doing."
  (let ((panel (generate-new-buffer "*herdr-test-panel*"))
        (terminal (generate-new-buffer "*herdr-test-terminal*")))
    (unwind-protect
        (progn
          (with-current-buffer panel
            (setq-local herdr-panel-refresh-function #'ignore))
          (with-current-buffer terminal
            (setq-local herdr-term--pane "w1:p1"))
          (cl-letf (((symbol-function 'herdr-session-stop) #'ignore))
            (herdr-ui-quit))
          (should-not (buffer-live-p panel))
          (should (buffer-live-p terminal)))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (buffer-live-p terminal) (kill-buffer terminal)))))

;;; _
(provide 'herdr-ui-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-ui-tests.el ends here
