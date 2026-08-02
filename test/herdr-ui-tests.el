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

;; The column is a list of panels and the weight each takes of it, and a
;; package outside herdr may add to it.  What is worth testing is the
;; arithmetic that turns weights into shares, and the promise that a
;; registration survives a package being loaded twice and a user having
;; customized the option beside it.

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
  "Evaluate BODY with the panel registry empty and no windows made.
`herdr-ui-tests--shown' collects what the layout asked for.  Both
panel variables are restored afterwards, so a test cannot leak a
registration into the next one."
  (declare (indent 0) (debug t))
  `(let ((herdr-ui-panels nil)
         (herdr-ui--added-panels nil)
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

;;; Registering A Panel

(ert-deftest herdr-ui-add-panel:appends-below-the-configured-ones ()
  "A package's panel goes under herdr's own, not among them.
Order in the column is the reading order, and a package cannot know
what belongs above it."
  (herdr-ui-with-layout
    (setq herdr-ui-panels '((spaces . 3) (agents . 2)))
    (herdr-ui-add-panel 'extra 1)
    (should (equal herdr-ui-panels '((spaces . 3) (agents . 2))))
    (should (equal herdr-ui--added-panels '((extra . 1))))))

(ert-deftest herdr-ui-add-panel:is-idempotent ()
  "Loading a package twice leaves one panel, not two.
A package registers from its own load, which happens again on every
recompile and on any `load-file'."
  (herdr-ui-with-layout
    (herdr-ui-add-panel 'extra 1)
    (herdr-ui-add-panel 'extra 5)
    (should (equal herdr-ui--added-panels '((extra . 1))))))

(ert-deftest herdr-ui-add-panel:defaults-to-the-smallest-share ()
  "A panel that does not say how much room it wants asks for little."
  (herdr-ui-with-layout
    (herdr-ui-add-panel 'extra)
    (should (equal herdr-ui--added-panels '((extra . 1))))))

(ert-deftest herdr-ui-add-panel:survives-a-customized-option ()
  "Customize writing `herdr-ui-panels' cannot drop a registration.
This is why the two are separate variables: `custom-set-variables'
runs whenever the user's custom file is read, which may be after the
package that registered."
  (herdr-ui-with-layout
    (herdr-ui-add-panel (herdr-ui-tests--panel "extra") 1)
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'car herdr-ui-tests--shown)
                   '("spaces" "extra")))))

;;; Sharing The Column

(ert-deftest herdr-ui--show-panels:divides-the-column-by-weight ()
  "Weights are shares of their own total, not fractions of the frame.
That is what lets a package add a panel without every other weight
having to be rewritten."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 3)
                            (,(herdr-ui-tests--panel "agents") . 2)))
    (herdr-ui-add-panel (herdr-ui-tests--panel "extra") 1)
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
