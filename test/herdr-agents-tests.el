;;; herdr-agents-tests.el --- Tests for herdr-agents  -*- lexical-binding:t -*-

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

;; The panel answers "who wants me", so what it lists and in what order is
;; the whole of it.  The tree is fed from a hand-written snapshot through
;; the fixture in herdr-session-tests.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-agents)
(require 'herdr-panel-tests)
(require 'herdr-session-tests)

;;; Fixtures

(defun herdr-agents-tests--agent (pane kind status)
  "Return an agent plist in PANE, of KIND, in STATUS."
  (list :pane_id pane :workspace_id "w1" :tab_id "w1:t1"
        :agent kind :agent_status status))

(defun herdr-agents-tests--panes (&rest agents)
  "Return the snapshot plist listing AGENTS."
  (list :agents (apply #'vector agents)))

;;; Ordering

(ert-deftest herdr-agents--sorted:puts-attention-first ()
  "An agent that wants the user outranks one that is busy.
The panel is read top down and often only at the top, so an order that
buries a blocked agent under working ones defeats the panel."
  (herdr-session-with-snapshot
      (herdr-agents-tests--panes
       (herdr-agents-tests--agent "w1:p1" "claude" "idle")
       (herdr-agents-tests--agent "w1:p2" "claude" "working")
       (herdr-agents-tests--agent "w1:p3" "claude" "blocked")
       (herdr-agents-tests--agent "w1:p4" "claude" "done"))
    (should (equal (mapcar (lambda (agent) (gethash "pane_id" agent))
                           (herdr-agents--sorted))
                   '("w1:p3" "w1:p4" "w1:p2" "w1:p1")))))

(ert-deftest herdr-agents--sorted:keeps-herdr-order-within-a-status ()
  "Agents sharing a status do not shuffle between redraws."
  (herdr-session-with-snapshot
      (herdr-agents-tests--panes
       (herdr-agents-tests--agent "w1:p1" "claude" "working")
       (herdr-agents-tests--agent "w1:p2" "codex" "working")
       (herdr-agents-tests--agent "w1:p3" "claude" "working"))
    (should (equal (mapcar (lambda (agent) (gethash "pane_id" agent))
                           (herdr-agents--sorted))
                   '("w1:p1" "w1:p2" "w1:p3")))))

;;; Hiding A Kind

(ert-deftest herdr-agents--sorted:lists-every-kind-by-default ()
  "Anything herdr calls an agent is one until told otherwise.
That includes a kind reported over the socket by a tool herdr does not
recognise, which is how a package puts something of its own here."
  (let ((herdr-agents-hidden-kinds nil))
    (herdr-session-with-snapshot
        (herdr-agents-tests--panes
         (herdr-agents-tests--agent "w1:p1" "claude" "working")
         (herdr-agents-tests--agent "w1:p2" "reporter" "blocked"))
      (should (eql (length (herdr-agents--sorted)) 2)))))

(ert-deftest herdr-agents--sorted:omits-a-hidden-kind ()
  "A kind with a panel of its own is listed there and not here.
Without this it would appear twice, once under each heading, and the
count of things wanting attention would be wrong."
  (let ((herdr-agents-hidden-kinds '("reporter")))
    (herdr-session-with-snapshot
        (herdr-agents-tests--panes
         (herdr-agents-tests--agent "w1:p1" "claude" "working")
         (herdr-agents-tests--agent "w1:p2" "reporter" "blocked"))
      (should (equal (mapcar (lambda (agent) (gethash "pane_id" agent))
                             (herdr-agents--sorted))
                     '("w1:p1"))))))

(ert-deftest herdr-agents--sorted:hides-by-kind-not-by-display-name ()
  "The detected kind decides, not what the row is labelled.
A kind may rename itself for display, and a hidden kind matched against
the label would stop hiding the moment that label changed."
  (let ((herdr-agents-hidden-kinds '("reporter")))
    (herdr-session-with-snapshot
        (list :agents
              (vector (append (herdr-agents-tests--agent
                               "w1:p2" "reporter" "blocked")
                              (list :display_agent "notes"))))
      (should (null (herdr-agents--sorted))))))

;;; Naming An Agent Instead Of Walking To It

(ert-deftest herdr-agents--read:offers-what-the-panel-lists ()
  "The prompt is the panel, so the loudest agent is the first candidate.
A prompt that reordered them would bury exactly the agent the panel
exists to raise."
  (herdr-session-with-snapshot
      (herdr-agents-tests--panes
       (herdr-agents-tests--agent "w1:p1" "claude" "idle")
       (herdr-agents-tests--agent "w1:p2" "claude" "working")
       (herdr-agents-tests--agent "w1:p3" "claude" "blocked"))
    (herdr-panel-tests-offline
      (herdr-panel-tests-choosing 0
        (should (equal (herdr-agents--read) "w1:p3"))
        (should (eql (length herdr-panel-tests--offered) 3))))))

(ert-deftest herdr-agents--read:refuses-when-there-is-nothing-to-name ()
  "A session with no agent says so rather than raising an empty prompt."
  (herdr-session-with-snapshot (herdr-agents-tests--panes)
    (herdr-panel-tests-offline
      (should-error (herdr-agents--read) :type 'user-error))))

;;; Spacing The List

(ert-deftest herdr-agents-refresh:uses-the-shared-item-spacing ()
  "Agent rows use the same leading and inter-entry gaps as other panels."
  (let ((agents (list (herdr-agents-tests--agent
                       "w1:p1" "claude" "working")
                      (herdr-agents-tests--agent
                       "w1:p2" "codex" "idle")))
        (herdr-agents-buffer-name " *herdr-agents-spacing-test*")
        received)
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-agents--sorted)
                   (lambda () agents))
                  ((symbol-function 'herdr-panel-current-pane) #'ignore)
                  ((symbol-function 'herdr-panel-insert-items)
                   (lambda (items insert-function)
                     (setq received items)
                     (mapc insert-function items)))
                  ((symbol-function 'herdr-agents--insert) #'ignore))
          (herdr-agents-refresh)
          (should (equal received agents)))
      (when-let* ((buffer (get-buffer herdr-agents-buffer-name)))
        (kill-buffer buffer)))))

;;; Titles

(ert-deftest herdr-agents--name:names-what-the-agent-is-working-on ()
  "The task title distinguishes agents sharing one workspace.
It leads the row because it is the field that changes: the workspace
they sit in is the same for both and says nothing."
  (let ((herdr-agents-icons '(("claude" . "◆"))))
    (herdr-session-with-snapshot
        (list :workspaces
              (vector (list :workspace_id "w1" :label "project"))
              :agents
              (vector (list :pane_id "w1:p1" :workspace_id "w1"
                            :agent "claude" :agent_status "working"
                            :terminal_title_stripped "fix agent rows")))
      (should (equal (substring-no-properties
                      (herdr-agents--name (car (herdr-session-agents))))
                     "◆ fix agent rows")))))

(ert-deftest herdr-agents--name:falls-back-to-the-workspace ()
  "An agent herdr reports no title for still has to name itself."
  (let ((herdr-agents-icons nil))
    (herdr-session-with-snapshot
        (list :workspaces
              (vector (list :workspace_id "w1" :label "project"))
              :agents
              (vector (list :pane_id "w1:p1" :workspace_id "w1"
                            :agent_status "working")))
      (let ((herdr-session-codex-index-file nil))
        (should (equal (substring-no-properties
                        (herdr-agents--name (car (herdr-session-agents))))
                       "project"))))))

(ert-deftest herdr-agents--entry:takes-one-line ()
  "The row carries nothing under its name."
  (herdr-session-with-snapshot
      (list :workspaces
            (vector (list :workspace_id "w1" :label "project"))
            :agents
            (vector (list :pane_id "w1:p1" :workspace_id "w1"
                          :agent "codex" :agent_status "working"
                          :terminal_title_stripped "fix agent rows")))
    (let ((entry (herdr-agents--entry (car (herdr-session-agents)) nil)))
      (should-not (plist-get entry :detail))
      (should-not (plist-get entry :aside)))))

;;; _
(provide 'herdr-agents-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-agents-tests.el ends here
