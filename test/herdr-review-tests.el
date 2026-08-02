;;; herdr-review-tests.el --- Tests for herdr-review  -*- lexical-binding:t -*-

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

;; What the panel reads out of the session tree, and what it does when the
;; script it drives is missing or fails.  The tree is fed from a
;; hand-written snapshot through the fixture in herdr-session-tests.

;; The lifecycle a review goes through is not tested here.  It lives in
;; the herdr-review script, in the herdr-review project, and so do its
;; tests: that project needs none of Emacs, and driving it from here would
;; make this suite depend on a checkout of it.

;;; Code:

(require 'ert)

(require 'herdr-review)
(require 'herdr-ui)
(require 'herdr-session-tests)

;;; Fixtures

(defun herdr-review-tests--agent (pane kind status &optional workspace)
  "Return an agent plist in PANE, of KIND, in STATUS, in WORKSPACE."
  (list :pane_id pane :workspace_id (or workspace "w1") :tab_id "w1:t1"
        :agent kind :agent_status status))

(defun herdr-review-tests--record (plist)
  "Return PLIST as the hash table herdr would have answered with.
The panel reads records with `gethash', so a plist would pass tests
that a real reply fails."
  (json-parse-string (json-serialize plist)))

;;; Listing Reviews

(ert-deftest herdr-review-list:lists-reviews-and-nothing-else ()
  "A coding agent is not a review, whatever state it is in."
  (herdr-session-with-snapshot
      (list :agents
            (vector (herdr-review-tests--agent "w1:p1" "claude" "blocked")
                    (herdr-review-tests--agent "w1:p2" "review" "blocked")
                    (herdr-review-tests--agent "w1:p3" "codex" "idle")))
    (should (equal (mapcar (lambda (review) (gethash "pane_id" review))
                           (herdr-review-list))
                   '("w1:p2")))))

(ert-deftest herdr-review-list:puts-attention-first ()
  "A review waiting for the operator sorts above one that is not."
  (herdr-session-with-snapshot
      (list :agents
            (vector (herdr-review-tests--agent "w1:p1" "review" "idle" "w1")
                    (herdr-review-tests--agent "w2:p1" "review" "blocked" "w2")))
    (should (equal (mapcar (lambda (review) (gethash "pane_id" review))
                           (herdr-review-list))
                   '("w2:p1" "w1:p1")))))

;;; Drawing A Row

(ert-deftest herdr-review--label:names-the-workspace-under-review ()
  "One review per workspace makes the workspace what the row is about."
  (herdr-session-with-snapshot
      (list :workspaces (vector (list :workspace_id "w1" :label "project")))
    (should (equal (herdr-review--label
                    (herdr-review-tests--record '(:workspace_id "w1")))
                   "project"))))

(ert-deftest herdr-review--label:falls-back-to-the-workspace-id ()
  "A workspace herdr has not described yet still gets a row."
  (herdr-session-with-snapshot (list :workspaces (vector))
    (should (equal (herdr-review--label
                    (herdr-review-tests--record '(:workspace_id "w9")))
                   "w9"))))

(ert-deftest herdr-review--summary:reads-the-metadata-token ()
  "What is waiting comes from herdr, not from reading the terminal."
  (should (equal (herdr-review--summary
                  (herdr-review-tests--record
                   '(:tokens (:summary "3 files to review"))))
                 "3 files to review"))
  (should (null (herdr-review--summary
                 (herdr-review-tests--record '(:pane_id "w1:p1"))))))

;;; Finding What To Review

(ert-deftest herdr-review--workspace-at-point:asks-the-panel-for-a-pane ()
  "Every panel answers with a pane, and the pane names the workspace.
Read off the section instead, and this would have to know how each
panel draws its rows."
  (herdr-session-with-snapshot
      (list :panes (vector (list :pane_id "w1:p1" :workspace_id "w1")))
    (with-temp-buffer
      (setq-local herdr-panel-pane-function (lambda () "w1:p1"))
      (should (equal (herdr-review--workspace-at-point) "w1")))))

(ert-deftest herdr-review--workspace-at-point:answers-nothing-off-a-row ()
  "A panel signals when point is on no row; that is not an answer."
  (herdr-session-with-snapshot (list :panes (vector))
    (with-temp-buffer
      (setq-local herdr-panel-pane-function
                  (lambda () (user-error "No review at point")))
      (should (null (herdr-review--workspace-at-point))))
    (with-temp-buffer
      (should (null (herdr-review--workspace-at-point))))))

;;; Reaching The Script

(ert-deftest herdr-review--run:refuses-a-script-it-cannot-find ()
  "A missing script is said once, not met as a process error.
The script is a project of its own, so not having it installed is an
ordinary state rather than a broken herdr."
  (let ((herdr-review-program "herdr-review-that-is-not-installed"))
    (should-error (herdr-review--run "open") :type 'user-error)))

(ert-deftest herdr-review--run:reports-what-the-script-said ()
  "A script that fails says so through the command that ran it.
A review that silently did not open looks exactly like one nobody
asked for."
  (let ((herdr-review-program "false"))
    (should-error (herdr-review--run "open") :type 'user-error)))

;;; Fitting Into herdr

(ert-deftest herdr-review:takes-reviews-out-of-the-agents-panel ()
  "Loading this file is what hides a review from the agents panel.
Listed in both, a review would be counted twice by anything reducing
over what wants attention."
  (should (member herdr-review-agent herdr-agents-hidden-kinds)))

(ert-deftest herdr-review:holds-a-place-in-the-column ()
  "The layout names this panel whether or not this file is loaded.
That is what makes requiring it the whole of the setup."
  (should (assq 'herdr-review-panel herdr-ui-panels)))

;;; _
(provide 'herdr-review-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-review-tests.el ends here
