;;; herdr-session-tests.el --- Tests for herdr-session  -*- lexical-binding:t -*-

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

;; The tree is fed from a hand-written snapshot rather than a server, so
;; that grouping and rollup can be driven into states a live session would
;; take a long time to reach.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-session)

;;; Fixtures

(defmacro herdr-session-with-snapshot (snapshot &rest body)
  "Evaluate BODY with the session tree set to SNAPSHOT.
SNAPSHOT is a plist in the shape herdr answers `session.snapshot'
with.  The tree is restored afterwards, so a test cannot leak into the
next one."
  (declare (indent 1) (debug t))
  `(let ((herdr-session--snapshot
          (json-parse-string (json-serialize ,snapshot)
                             :false-object nil :null-object nil)))
     ,@body))

(defun herdr-session-test-workspace (id label status &optional repo-key repo)
  "Return a workspace plist called ID, labelled LABEL, in STATUS.
REPO-KEY and REPO give it a worktree, which is what puts several
workspaces into one space."
  (append (list :workspace_id id :label label :agent_status status
                :number 1 :focused :false :pane_count 1 :tab_count 1
                :active_tab_id (concat id ":t1"))
          (when repo-key
            (list :worktree (list :repo_key repo-key
                                  :repo_name (or repo repo-key)
                                  :repo_root "/repo"
                                  :checkout_path "/repo"
                                  :is_linked_worktree :false)))))

;;; Status Rollup

(ert-deftest herdr-session-status-max:ranks-by-attention ()
  "Work that finished unseen outranks work still running.
This is herdr's own order, and getting it wrong would hide exactly the
agent that wants the user."
  (should (equal (herdr-session-status-max '("idle" "working")) "working"))
  (should (equal (herdr-session-status-max '("working" "done")) "done"))
  (should (equal (herdr-session-status-max '("done" "blocked")) "blocked"))
  (should (equal (herdr-session-status-max '("unknown" "idle")) "idle")))

(ert-deftest herdr-session-status-max:handles-nothing ()
  "A space with no statuses is unknown, not an error."
  (should (equal (herdr-session-status-max nil) "unknown"))
  (should (equal (herdr-session-status-max '(nil)) "unknown")))

;;; Spaces

(ert-deftest herdr-session-spaces:groups-by-repository ()
  "Workspaces checked out of one repository share a space."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle"
                                                  "repo-a" "herdr")
                    (herdr-session-test-workspace "w2" "fix" "blocked"
                                                  "repo-a" "herdr")
                    (herdr-session-test-workspace "w3" "other" "idle")))
    (let ((spaces (herdr-session-spaces)))
      (should (eql (length spaces) 2))
      (should (equal (plist-get (car spaces) :label) "herdr"))
      (should (eql (length (plist-get (car spaces) :workspaces)) 2))
      (should (equal (plist-get (cadr spaces) :label) "other")))))

(ert-deftest herdr-session-spaces:shows-the-loudest-member ()
  "A space reports the state of whichever member wants attention most."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "main" "idle"
                                                  "repo-a" "herdr")
                    (herdr-session-test-workspace "w2" "fix" "blocked"
                                                  "repo-a" "herdr")))
    (should (equal (plist-get (car (herdr-session-spaces)) :agent-status)
                   "blocked"))))

(ert-deftest herdr-session-spaces:keeps-workspace-order ()
  "Spaces appear in the order herdr reports their first member."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "first" "idle")
                    (herdr-session-test-workspace "w2" "second" "idle")
                    (herdr-session-test-workspace "w3" "third" "idle")))
    (should (equal (mapcar (lambda (space) (plist-get space :label))
                           (herdr-session-spaces))
                   '("first" "second" "third")))))

(ert-deftest herdr-session-spaces:ungrouped-workspace-keeps-its-label ()
  "A lone checkout is its own space and is named after itself.
Naming it after the repository would rename every unrelated workspace
to the same thing."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "only" "idle"
                                                  "repo-a" "herdr")))
    (let ((space (car (herdr-session-spaces))))
      (should (equal (plist-get space :label) "only"))
      (should (eql (length (plist-get space :workspaces)) 1)))))

(ert-deftest herdr-session-space-key:falls-back-to-the-workspace ()
  "A workspace herdr reports no worktree for still gets its own space."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (herdr-session-test-workspace "w1" "plain" "idle")))
    (let ((workspace (car (herdr-session-workspaces))))
      (should (equal (herdr-session-space-key workspace) "w1")))))

;;; Reading the Tree

(ert-deftest herdr-session-tabs:filters-by-workspace ()
  "A panel asks for one workspace's tabs, not for all of them."
  (herdr-session-with-snapshot
      (list :tabs (vector (list :tab_id "w1:t1" :workspace_id "w1")
                          (list :tab_id "w1:t2" :workspace_id "w1")
                          (list :tab_id "w2:t1" :workspace_id "w2")))
    (should (eql (length (herdr-session-tabs)) 3))
    (should (equal (mapcar (lambda (tab) (gethash "tab_id" tab))
                           (herdr-session-tabs "w1"))
                   '("w1:t1" "w1:t2")))))

(ert-deftest herdr-session-agent:finds-the-agent-of-a-pane ()
  "The panels join panes to agents by pane identifier."
  (herdr-session-with-snapshot
      (list :agents (vector (list :pane_id "w1:p1" :agent "claude"
                                  :agent_status "working")))
    (should (equal (gethash "agent" (herdr-session-agent "w1:p1"))
                   "claude"))
    (should (null (herdr-session-agent "w9:p9")))))

(ert-deftest herdr-session-reading:tolerates-an-empty-tree ()
  "Every reader answers before the first snapshot has arrived."
  (let ((herdr-session--snapshot nil))
    (should (null (herdr-session-workspaces)))
    (should (null (herdr-session-tabs)))
    (should (null (herdr-session-panes)))
    (should (null (herdr-session-agents)))
    (should (null (herdr-session-spaces)))
    (should (null (herdr-session-protocol)))))

;;; Refreshing

(ert-deftest herdr-session--note-event:defers-and-coalesces ()
  "A burst of events costs one refresh, and none from the filter.
Refreshing inside the event callback would block a process filter,
where quitting is inhibited."
  (let ((herdr-session--timer nil)
        (herdr-session-refresh-delay 0.05)
        (refreshes 0))
    (cl-letf (((symbol-function 'herdr-session-refresh)
               (lambda () (cl-incf refreshes))))
      (unwind-protect
          (progn
            (dotimes (_ 5) (herdr-session--note-event nil))
            (should (eql refreshes 0))
            (should (timerp herdr-session--timer))
            (dotimes (_ 20)
              (when (zerop refreshes) (accept-process-output nil 0.02)))
            (should (eql refreshes 1))
            (should (null herdr-session--timer)))
        (when (timerp herdr-session--timer)
          (cancel-timer herdr-session--timer))))))

(ert-deftest herdr-session-refresh:announces-only-real-changes ()
  "A snapshot that draws the same must not make the panels redraw.
An agent's pane reports an event several times a second, and almost
none of them change anything a panel shows."
  (let* ((herdr-session--snapshot nil)
         (herdr-session--fingerprint nil)
         (announcements 0)
         (status "idle")
         (revision 0)
         (herdr-session-change-hook
          (list (lambda () (setq announcements (1+ announcements))))))
    (cl-letf (((symbol-function 'herdr-api-request)
               (lambda (&rest _)
                 (setq revision (1+ revision))
                 (json-parse-string
                  (json-serialize
                   (list :snapshot
                         (list :workspaces
                               (vector (list :workspace_id "w1"
                                             :label "one"
                                             :agent_status status
                                             :focused t))
                               ;; Churn a panel never draws.
                               :panes
                               (vector (list :pane_id "w1:p1"
                                             :agent_status status
                                             :focused t
                                             :revision revision)))))
                  :false-object nil :null-object nil))))
      (herdr-session-refresh)
      (should (eql announcements 1))
      (herdr-session-refresh)
      (herdr-session-refresh)
      (should (eql announcements 1))
      (setq status "blocked")
      (herdr-session-refresh)
      (should (eql announcements 2))
      ;; Forcing is how a panel that lost its buffer gets redrawn.
      (herdr-session-refresh t)
      (should (eql announcements 3)))))

;;; _
(provide 'herdr-session-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-session-tests.el ends here
