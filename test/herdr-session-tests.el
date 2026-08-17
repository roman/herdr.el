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

(defmacro herdr-session-with-unread (&rest body)
  "Evaluate BODY with this Emacs deciding which finishes are unread.
The tables start empty, so a test opens on a session it has never
looked at, and neither table outlives it."
  (declare (indent 0) (debug t))
  `(let ((herdr-session-finish-seen-by 'emacs)
         (herdr-session--reported (make-hash-table :test #'equal))
         (herdr-session--unread (make-hash-table :test #'equal)))
     ,@body))

(defun herdr-session-test-tree (agents)
  "Return a snapshot holding AGENTS, each a (PANE-ID STATUS) list.
Every agent sits in tab `w1:t1' of workspace `w1', both of them idle:
what varies in these tests is an agent's status, and the rollups above
it are there to be raised by one."
  (list :workspaces
        (vector (herdr-session-test-workspace "w1" "herdr" "idle"))
        :tabs
        (vector (list :tab_id "w1:t1" :workspace_id "w1"
                      :agent_status "idle" :number 1))
        :agents
        (vconcat
         (mapcar (pcase-lambda (`(,pane ,status))
                   (list :pane_id pane :agent "claude"
                         :agent_status status
                         :tab_id "w1:t1" :workspace_id "w1"))
                 agents))))

(defmacro herdr-session-looking-at (agents &rest body)
  "Set the tree to AGENTS, note which of them finished, then run BODY.
AGENTS is a list of (PANE-ID STATUS).  BODY runs inside the tree, so
that it can ask what the session now reports."
  (declare (indent 1) (debug t))
  `(herdr-session-with-snapshot (herdr-session-test-tree ,agents)
     (herdr-session--note-finishes)
     ,@body))

;;; Finishes This Emacs Has Not Seen

(ert-deftest herdr-session-status:takes-herdrs-word-by-default ()
  "Nothing is marked while herdr owns the question.
The default has to leave a session behaving as it always did, however
long this Emacs has been watching it."
  (let ((herdr-session-finish-seen-by 'herdr)
        (herdr-session--reported (make-hash-table :test #'equal))
        (herdr-session--unread (make-hash-table :test #'equal)))
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle"))
      (should-not (herdr-session-unread-p "w1:p1"))
      (should (equal (herdr-session-status (herdr-session-agent "w1:p1"))
                     "idle")))))

(ert-deftest herdr-session--note-finishes:says-nothing-on-the-first-look ()
  "A first sighting is not a transition.
Read as one, every agent resting when Emacs connected would come up
green at once, which is what starting Emacs would look like."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "idle") ("w1:p2" "done"))
      (should-not (herdr-session-unread-p "w1:p1"))
      (should-not (herdr-session-unread-p "w1:p2")))))

(ert-deftest herdr-session-status:reports-an-unread-finish-as-done ()
  "A finish herdr called seen is reported as done until it is read.
herdr writes `seen' from whether the pane is its own workspace's
active tab and whether the terminal running herdr holds focus, so a
workspace of one tab reaches \"done\" never."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle"))
      (should (herdr-session-unread-p "w1:p1"))
      (should (equal (herdr-session-status (herdr-session-agent "w1:p1"))
                     "done")))))

(ert-deftest herdr-session-status:raises-the-tab-and-the-workspace ()
  "A row above an unread pane says so, or a collapsed space hides it.
herdr rolls a pane's status up itself, and the roll-up it sent was
computed from the status it also sent, so raising the pane alone would
leave the two disagreeing."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle"))
      (should (equal (herdr-session-status (herdr-session-workspace "w1"))
                     "done"))
      (should (equal (herdr-session-status (car (herdr-session-tabs "w1")))
                     "done")))))

(ert-deftest herdr-session-status:leaves-a-louder-rollup-alone ()
  "Only an idle row is raised.
A workspace herdr reports as working has something running in it, and
saying it finished would be false as well as quieter."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working") ("w1:p2" "working")))
    (herdr-session-with-snapshot
        (let ((tree (herdr-session-test-tree '(("w1:p1" "idle")
                                               ("w1:p2" "working")))))
          (plist-put tree :workspaces
                     (vector (herdr-session-test-workspace
                              "w1" "herdr" "working"))))
      (herdr-session--note-finishes)
      (should (herdr-session-unread-p "w1:p1"))
      (should (equal (herdr-session-status (herdr-session-workspace "w1"))
                     "working")))))

(ert-deftest herdr-session--note-finishes:clears-when-work-starts-again ()
  "Answering an agent is reading its last finish.
This is the ordinary way a mark goes away: the reader comes back,
types, and the pane leaves the state it was marked in."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle")))
    (herdr-session-looking-at '(("w1:p1" "working"))
      (should-not (herdr-session-unread-p "w1:p1")))))

(ert-deftest herdr-session-mark-seen:clears-one-pane ()
  "Going to a pane deliberately is reading it."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working") ("w1:p2" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle") ("w1:p2" "idle"))
      (herdr-session-mark-seen "w1:p1")
      (should-not (herdr-session-unread-p "w1:p1"))
      (should (herdr-session-unread-p "w1:p2")))))

(ert-deftest herdr-session--note-finishes:stays-marked-while-idle ()
  "A finish nobody read is still unread on the next look.
The tree is re-read several times a second, and a mark that survived
only one reading would flash and go."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle")))
    (herdr-session-looking-at '(("w1:p1" "idle"))
      (should (herdr-session-unread-p "w1:p1")))))

(ert-deftest herdr-session--note-finishes:forgets-a-pane-that-is-gone ()
  "A pane herdr no longer reports takes its mark with it.
Left behind, the table would grow for as long as Emacs runs and would
raise the next pane that happened to reuse the identifier."
  (herdr-session-with-unread
    (herdr-session-looking-at '(("w1:p1" "working")))
    (herdr-session-looking-at '(("w1:p1" "idle")))
    (herdr-session-looking-at '(("w1:p2" "working"))
      (should-not (herdr-session-unread-p "w1:p1")))))

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

(ert-deftest herdr-session-agent-title:reads-a-codex-rename ()
  "A Codex `/rename' value replaces its project-only terminal title."
  (let ((file (make-temp-file "herdr-codex-index-"))
        (herdr-session--codex-index-cache nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert
             "{\"id\":\"session-1\",\"thread_name\":\"fix agent rows\"}\n"))
          (let ((herdr-session-codex-index-file file)
                (agent
                 (json-parse-string
                  (json-serialize
                   '(:pane_id "w1:p1"
                     :agent "codex"
                     :terminal_title_stripped "project"
                     :agent_session
                     (:agent "codex" :kind "id"
                      :source "herdr:codex" :value "session-1"))))))
            (should (equal (herdr-session-agent-title agent)
                           "fix agent rows"))))
      (delete-file file))))

(ert-deftest herdr-session-agent-title:prefers-a-herdr-name ()
  "An explicit herdr name wins over an agent-specific title."
  (let ((herdr-session-codex-index-file nil)
        (agent
         (json-parse-string
          (json-serialize
           '(:pane_id "w1:p1" :name "reviewer" :agent "codex"
             :terminal_title_stripped "project")))))
    (should (equal (herdr-session-agent-title agent) "reviewer"))))

(ert-deftest herdr-session-agent-title:ignores-an-unnamed-pane-id ()
  "Herdr's pane-id fallback is not presented as an assigned name."
  (let ((agent
         (json-parse-string
          (json-serialize
           '(:pane_id "w1:p1" :name "w1:p1" :agent "claude"
             :terminal_title_stripped "renamed task")))))
    (should (equal (herdr-session-agent-title agent) "renamed task"))))

(ert-deftest herdr-session-agent-title:survives-a-malformed-index-line ()
  "An interrupted Codex index write does not hide later valid names."
  (let ((file (make-temp-file "herdr-codex-index-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{broken\n"
                    "[]\n"
                    "{\"id\":\"good\",\"thread_name\":\"usable\"}\n"))
          (should (equal (gethash "good"
                                  (herdr-session--read-codex-index file))
                         "usable")))
      (delete-file file))))

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
         (cwd "/tmp/one")
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
                                             :cwd cwd
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
      ;; A terminal buffer consumes cwd even though no panel draws it.
      (setq cwd "/tmp/two")
      (herdr-session-refresh)
      (should (eql announcements 3))
      ;; Forcing is how a panel that lost its buffer gets redrawn.
      (herdr-session-refresh t)
      (should (eql announcements 4)))))

(ert-deftest herdr-session-start:polls-for-what-events-omit ()
  "A poll runs alongside the events, because some changes have none.
A shell changing directory renames its workspace and reports nothing,
so a client listening only to events never learns."
  (let ((herdr-session--poll-timer nil)
        (herdr-session--subscription nil)
        (herdr-session-poll-interval 0.05)
        (refreshes 0))
    (cl-letf (((symbol-function 'herdr-session-refresh)
               (lambda (&rest _) (cl-incf refreshes)))
              ((symbol-function 'herdr-api-subscribe)
               (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (herdr-session-start)
            (should (timerp herdr-session--poll-timer))
            (let ((before refreshes))
              (dotimes (_ 30)
                (when (eql refreshes before)
                  (accept-process-output nil 0.02)))
              (should (> refreshes before))))
        (herdr-session-stop))
      (should (null herdr-session--poll-timer)))))

(ert-deftest herdr-session-start:honours-a-disabled-poll ()
  "Polling can be turned off for a session that only wants events."
  (let ((herdr-session--poll-timer nil)
        (herdr-session--subscription nil)
        (herdr-session-poll-interval nil))
    (cl-letf (((symbol-function 'herdr-session-refresh) #'ignore)
              ((symbol-function 'herdr-api-subscribe) (lambda (&rest _) nil)))
      (unwind-protect
          (progn (herdr-session-start)
                 (should (null herdr-session--poll-timer)))
        (herdr-session-stop)))))

;;; _
(provide 'herdr-session-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-session-tests.el ends here
