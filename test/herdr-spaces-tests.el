;;; herdr-spaces-tests.el --- Tests for herdr-spaces  -*- lexical-binding:t -*-

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

;; Which pane a workspace leads to, and what the panel offers when a
;; workspace is named rather than walked to.  The tree is fed from a
;; hand-written snapshot through the fixture in herdr-session-tests.

;; Grouping itself is tested in herdr-session-tests, where it lives.  What
;; matters here is that the prompt follows the grouped order, because that
;; is the order the column is read in.

;;; Code:

(require 'ert)

(require 'herdr-panel-tests)
(require 'herdr-session-tests)
(require 'herdr-spaces)

;;; Fixtures

(defun herdr-spaces-tests--pane (id workspace)
  "Return a pane plist called ID, in the active tab of WORKSPACE.
No `cwd': nil is the one value `json-serialize' will not round trip,
and a pane that reports no directory is what a shell in a plain
terminal looks like."
  (list :pane_id id :workspace_id workspace
        :tab_id (concat workspace ":t1")))

(defmacro herdr-spaces-with-snapshot (snapshot &rest body)
  "Evaluate BODY with the tree set to SNAPSHOT and git left unasked.
Asking git would run a subprocess against a directory no fixture has,
and none of what it answers is what these tests are about."
  (declare (indent 1) (debug t))
  `(let ((herdr-spaces-git nil))
     (herdr-session-with-snapshot ,snapshot ,@body)))

;;; Finding The Pane For A Workspace

(ert-deftest herdr-spaces--pane:answers-with-the-active-tab ()
  "A workspace leads to the pane herdr shows when it is focused."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "herdr" "idle"))
            :panes (vector (herdr-spaces-tests--pane "w1:p1" "w1")))
    (should (equal (herdr-spaces--pane (herdr-session-workspace "w1"))
                   "w1:p1"))))

(ert-deftest herdr-spaces--pane:answers-nothing-for-an-empty-workspace ()
  "A workspace with no pane has nothing to show, and says so with nil."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "herdr" "idle"))
            :panes (vector))
    (should (null (herdr-spaces--pane (herdr-session-workspace "w1"))))))

;;; Naming A Workspace Instead Of Walking To It

(ert-deftest herdr-spaces--read:follows-the-grouped-order ()
  "The prompt lists workspaces as the column draws them.
Checkouts of one repository sit together there, so a prompt in herdr's
flat order would put a reader somewhere else than the panel did."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle" "repo-a")
                    (herdr-session-test-workspace "w2" "other" "idle")
                    (herdr-session-test-workspace "w3" "fix" "idle" "repo-a"))
            :panes
            (vector (herdr-spaces-tests--pane "w1:p1" "w1")
                    (herdr-spaces-tests--pane "w2:p1" "w2")
                    (herdr-spaces-tests--pane "w3:p1" "w3")))
    (herdr-panel-tests-offline
      (herdr-panel-tests-choosing 1
        (should (equal (herdr-spaces--read) "w3:p1"))
        (should (eql (length herdr-panel-tests--offered) 3))))))

(ert-deftest herdr-spaces--read:offers-a-workspace-once ()
  "A space is not offered beside its own members.
The group leads to its first member, so listing both would put that
member in the prompt twice under two names."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle" "repo-a")
                    (herdr-session-test-workspace "w2" "fix" "idle" "repo-a"))
            :panes
            (vector (herdr-spaces-tests--pane "w1:p1" "w1")
                    (herdr-spaces-tests--pane "w2:p1" "w2")))
    (herdr-panel-tests-offline
      (herdr-panel-tests-choosing 0
        (herdr-spaces--read)
        (should (eql (length herdr-panel-tests--offered) 2))))))

(ert-deftest herdr-spaces--read:leaves-out-a-workspace-with-no-pane ()
  "A candidate that could not be visited is not offered."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle")
                    (herdr-session-test-workspace "w2" "other" "idle"))
            :panes (vector (herdr-spaces-tests--pane "w2:p1" "w2")))
    (herdr-panel-tests-offline
      (herdr-panel-tests-choosing 0
        (should (equal (herdr-spaces--read) "w2:p1"))
        (should (eql (length herdr-panel-tests--offered) 1))))))

(ert-deftest herdr-spaces--read:refuses-when-there-is-nowhere-to-go ()
  "An empty session says so rather than raising an empty prompt."
  (herdr-spaces-with-snapshot (list :workspaces (vector) :panes (vector))
    (herdr-panel-tests-offline
      (should-error (herdr-spaces--read) :type 'user-error))))

;;; _
(provide 'herdr-spaces-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-spaces-tests.el ends here
