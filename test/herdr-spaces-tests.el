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

(defun herdr-spaces-tests--fill-at (text)
  "Return the faces on the first character of TEXT, as a list.
Point is left where the search ended.  Rows are found by what they
say, because a space of several members draws its heading and its
members in an order this does not want to depend on."
  (goto-char (point-min))
  (search-forward text)
  (ensure-list (get-text-property (match-beginning 0) 'face)))

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

;;; Filling A Space That Wants The User

(ert-deftest herdr-spaces--insert:fills-a-group-holding-a-blocked-member ()
  "A space says that something inside it is waiting, collapsed or not.
The heading carries the loudest status among its members, so a group
drawn without the fill would hide the one row that wanted attention
behind a heading that looked quiet."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle"
                                                 "repo-a")
                    (herdr-session-test-workspace "w2" "fix" "blocked"
                                                  "repo-a"))
            :panes
            (vector (herdr-spaces-tests--pane "w1:p1" "w1")
                    (herdr-spaces-tests--pane "w2:p1" "w2")))
    (with-temp-buffer
      (magit-insert-section (herdr-spaces-tests-root)
        (herdr-spaces--insert (car (herdr-session-spaces)) nil))
      (should (memq 'herdr-panel-attention-blocked
                    (herdr-spaces-tests--fill-at "repo-a")))
      (should (memq 'herdr-panel-attention-blocked
                    (herdr-spaces-tests--fill-at "fix")))
      (should-not (memq 'herdr-panel-attention-blocked
                        (herdr-spaces-tests--fill-at "main"))))))

(ert-deftest herdr-spaces--insert:leaves-a-quiet-group-unfilled ()
  "A space with nothing waiting in it draws as it always did."
  (herdr-spaces-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle"
                                                 "repo-a")
                    (herdr-session-test-workspace "w2" "fix" "working"
                                                  "repo-a"))
            :panes
            (vector (herdr-spaces-tests--pane "w1:p1" "w1")
                    (herdr-spaces-tests--pane "w2:p1" "w2")))
    (with-temp-buffer
      (magit-insert-section (herdr-spaces-tests-root)
        (herdr-spaces--insert (car (herdr-session-spaces)) nil))
      (should-not (memq 'herdr-panel-attention-blocked
                        (herdr-spaces-tests--fill-at "repo-a"))))))

;;; _
(provide 'herdr-spaces-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-spaces-tests.el ends here
