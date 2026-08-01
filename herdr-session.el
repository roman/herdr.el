;;; herdr-session.el --- Track the herdr session tree  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes tools

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

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

;; One copy of the herdr session tree, kept current, for every panel to
;; read.  Panels do not talk to the server; they read here and redraw when
;; `herdr-session-change-hook' tells them the tree moved.

;; The tree is replaced wholesale on every change rather than patched from
;; the events that announced it.  Two facts make that the simpler design
;; and not merely the lazier one.  Only the lifecycle events carry a whole
;; node, while the focus events carry bare identifiers.  And the agent list
;; has no event at all: it exists only in a snapshot, and it holds the
;; name, the display name and the metadata tokens that a pane node does not
;; carry.  Patching would therefore reproduce half the server's bookkeeping
;; and still need a snapshot for the other half.  A snapshot is one short
;; connection, and bursts are coalesced by `herdr-session-refresh-delay'.

;; Refreshing is always deferred through a timer, never run from the event
;; callback.  A callback runs inside a process filter, where quitting is
;; inhibited, so a blocking request issued there would freeze Emacs for the
;; whole timeout with no way to interrupt it.

;;; Code:

(require 'seq)

(require 'herdr-api)

;;; Options

(defgroup herdr-session nil
  "The herdr session tree behind the herdr.el panels."
  :group 'herdr-api
  :prefix "herdr-session-")

(defcustom herdr-session-refresh-delay 0.15
  "Seconds to wait for more events before refreshing the tree.
herdr reports a burst of events for one action, and each would
otherwise cost a snapshot."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-session
  :type 'number)

(defcustom herdr-session-events
  '("workspace.created" "workspace.updated" "workspace.renamed"
    "workspace.moved" "workspace.reordered" "workspace.closed"
    "workspace.focused" "worktree.created" "worktree.opened"
    "worktree.removed" "tab.created" "tab.closed" "tab.focused"
    "tab.renamed" "tab.moved" "pane.created" "pane.closed"
    "pane.updated" "pane.focused" "pane.moved" "pane.exited"
    "pane.agent_detected")
  "Events that make the session tree stale.
`pane.agent_status_changed' is deliberately absent: it is subscribed
per pane, while `pane.updated' reports the same change for every pane
at once."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-session
  :type '(repeat string))

;;; Variables

(defvar herdr-session-change-hook nil
  "Hook run after the session tree changed.
Panels add themselves here to redraw.  It runs outside any process
filter, so a function on it may call the herdr API.")

(defvar herdr-session--snapshot nil
  "The last snapshot hash-table, or nil before the first refresh.")

(defvar herdr-session--fingerprint nil
  "Fingerprint of the last snapshot the panels were told about.")

(defvar herdr-session--subscription nil
  "Process carrying the event subscription, or nil when stopped.")

(defvar herdr-session--timer nil
  "Timer of a pending refresh, or nil when none is due.")

(defvar herdr-session--closed-reason nil
  "Why the event subscription ended, or nil while it is healthy.")

;;; Lifecycle

;;;###autoload
(defun herdr-session-start ()
  "Begin tracking the herdr session tree.
Take a snapshot, then keep it current from the event stream.  Calling
this again restarts the subscription, which is how a session recovers
after the server was restarted."
  (interactive)
  (herdr-session-stop)
  (herdr-session-refresh)
  (setq herdr-session--subscription
        (herdr-api-subscribe herdr-session-events
                             #'herdr-session--note-event
                             #'herdr-session--note-closed))
  herdr-session--subscription)

;;;###autoload
(defun herdr-session-stop ()
  "Stop tracking the session tree and forget it."
  (interactive)
  (when herdr-session--timer
    (cancel-timer herdr-session--timer))
  (setq herdr-session--timer nil)
  (herdr-api-unsubscribe herdr-session--subscription)
  (setq herdr-session--subscription nil))

(defun herdr-session-live-p ()
  "Return non-nil while the session tree is being kept current."
  (process-live-p herdr-session--subscription))

(defun herdr-session-refresh (&optional force)
  "Replace the session tree with a fresh snapshot, then announce it.
The announcement is skipped when nothing a panel would draw
differently has changed, unless FORCE says otherwise.  A pane running
an agent reports an event several times a second, and redrawing every
panel that often is work no one sees.

This blocks, so it must not run from a process filter; see
`herdr-session--note-event'."
  (interactive "p")
  (setq herdr-session--snapshot
        (gethash "snapshot" (herdr-api-request "session.snapshot")))
  (let ((fingerprint (herdr-session--fingerprint)))
    (when (or force (not (equal fingerprint herdr-session--fingerprint)))
      (setq herdr-session--fingerprint fingerprint)
      (run-hooks 'herdr-session-change-hook)))
  herdr-session--snapshot)

(defun herdr-session--fingerprint ()
  "Return what the panels draw, as a value that can be compared.
Only the fields a panel renders take part, so the churn of revisions
and scroll positions does not count as a change."
  (list (mapcar (lambda (workspace)
                  (list (gethash "workspace_id" workspace)
                        (gethash "label" workspace)
                        (gethash "agent_status" workspace)
                        (gethash "focused" workspace)
                        (herdr-session-space-key workspace)))
                (herdr-session-workspaces))
        (mapcar (lambda (tab)
                  (list (gethash "tab_id" tab)
                        (gethash "label" tab)
                        (gethash "agent_status" tab)
                        (gethash "focused" tab)))
                (herdr-session-tabs))
        (mapcar (lambda (agent)
                  (list (gethash "pane_id" agent)
                        (gethash "agent" agent)
                        (gethash "agent_status" agent)
                        (gethash "terminal_title_stripped" agent)
                        (gethash "focused" agent)))
                (herdr-session-agents))
        (mapcar (lambda (pane)
                  (list (gethash "pane_id" pane)
                        (gethash "agent_status" pane)
                        (gethash "focused" pane)))
                (herdr-session-panes))))

(defun herdr-session--note-event (_event)
  "Mark the tree stale and schedule a refresh.
The refresh is deferred rather than run here, because this is a process
filter: quitting is inhibited, so a blocking request would freeze Emacs
until it timed out."
  (unless herdr-session--timer
    (setq herdr-session--timer
          (run-at-time herdr-session-refresh-delay nil
                       #'herdr-session--refresh-now))))

(defun herdr-session--refresh-now ()
  "Run a deferred refresh, keeping a failure from killing the timer."
  (setq herdr-session--timer nil)
  (with-demoted-errors "herdr-session refresh: %S"
    (herdr-session-refresh)))

(defun herdr-session--note-closed (reason)
  "Record REASON for the subscription ending and tell the panels."
  (setq herdr-session--closed-reason reason
        herdr-session--subscription nil)
  (message "herdr-session: event stream ended (%s); %s resumes it"
           reason (substitute-command-keys "\\[herdr-session-start]"))
  (run-hooks 'herdr-session-change-hook))

;;; Reading the Tree

(defun herdr-session--nodes (key)
  "Return the KEY array of the snapshot as a list."
  (append (and herdr-session--snapshot
               (gethash key herdr-session--snapshot))
          nil))

(defun herdr-session-workspaces ()
  "Return every workspace, in the order herdr reports them."
  (herdr-session--nodes "workspaces"))

(defun herdr-session-tabs (&optional workspace-id)
  "Return every tab, or only those of WORKSPACE-ID."
  (let ((tabs (herdr-session--nodes "tabs")))
    (if workspace-id
        (seq-filter (lambda (tab)
                      (equal (gethash "workspace_id" tab) workspace-id))
                    tabs)
      tabs)))

(defun herdr-session-panes (&optional tab-id)
  "Return every pane, or only those of TAB-ID."
  (let ((panes (herdr-session--nodes "panes")))
    (if tab-id
        (seq-filter (lambda (pane) (equal (gethash "tab_id" pane) tab-id))
                    panes)
      panes)))

(defun herdr-session-agents ()
  "Return every agent herdr has detected."
  (herdr-session--nodes "agents"))

(defun herdr-session-pane (pane-id)
  "Return the pane called PANE-ID, or nil."
  (seq-find (lambda (pane) (equal (gethash "pane_id" pane) pane-id))
            (herdr-session-panes)))

(defun herdr-session-agent (pane-id)
  "Return the agent running in PANE-ID, or nil."
  (seq-find (lambda (agent) (equal (gethash "pane_id" agent) pane-id))
            (herdr-session-agents)))

(defun herdr-session-workspace (workspace-id)
  "Return the workspace called WORKSPACE-ID, or nil."
  (seq-find (lambda (workspace)
              (equal (gethash "workspace_id" workspace) workspace-id))
            (herdr-session-workspaces)))

(defun herdr-session-protocol ()
  "Return the protocol version herdr reported, or nil."
  (and herdr-session--snapshot
       (gethash "protocol" herdr-session--snapshot)))

;;; Spaces

;; herdr groups workspaces that share a git repository into one space, and
;; shows the group's worst state on the parent row.  That grouping lives in
;; the TUI rather than in the API, so it is rebuilt here from the worktree
;; each workspace reports.  The per-workspace and per-tab rollups are not
;; rebuilt: herdr computes those already and puts them on the wire.

(defconst herdr-session-status-priority
  '(("blocked" . 4) ("done" . 3) ("working" . 2)
    ("idle" . 1) ("unknown" . 0))
  "How loudly each agent status asks for attention.
A space shows the loudest status among its workspaces.  This is
herdr's own order, in which work that finished unseen outranks work
still running.")

(defun herdr-session-status-priority (status)
  "Return how loudly STATUS asks for attention, as a number."
  (or (cdr (assoc status herdr-session-status-priority)) 0))

(defun herdr-session-status-max (statuses)
  "Return the loudest of STATUSES, or \"unknown\" when there are none."
  (or (car (seq-sort-by #'herdr-session-status-priority #'>
                        (delq nil statuses)))
      "unknown"))

(defun herdr-session-space-key (workspace)
  "Return the key of the space WORKSPACE belongs to.
Workspaces checked out of one repository share its key.  A workspace
herdr reports no worktree for is its own space, keyed by its
identifier, so that it still appears exactly once."
  (let ((worktree (gethash "worktree" workspace)))
    (or (and worktree (gethash "repo_key" worktree))
        (gethash "workspace_id" workspace))))

(defun herdr-session-spaces ()
  "Return the spaces of this session, in workspace order.
Each space is a plist with `:key', `:label', `:workspaces' and
`:agent-status', the last being the loudest status among its members.
A space of one workspace is that workspace, which is how herdr renders
an ungrouped checkout."
  (let ((order nil)
        (members (make-hash-table :test #'equal)))
    (dolist (workspace (herdr-session-workspaces))
      (let ((key (herdr-session-space-key workspace)))
        (unless (gethash key members)
          (push key order))
        (puthash key (append (gethash key members) (list workspace))
                 members)))
    (mapcar (lambda (key)
              (let ((workspaces (gethash key members)))
                (list :key key
                      :label (herdr-session--space-label workspaces)
                      :workspaces workspaces
                      :agent-status
                      (herdr-session-status-max
                       (mapcar (lambda (workspace)
                                 (gethash "agent_status" workspace))
                               workspaces)))))
            (nreverse order))))

(defun herdr-session--space-label (workspaces)
  "Return the label for the space made of WORKSPACES.
A group takes the repository's name, which is what its members have in
common; a lone workspace keeps its own label."
  (let* ((first (car workspaces))
         (worktree (gethash "worktree" first)))
    (if (and worktree (cdr workspaces))
        (gethash "repo_name" worktree)
      (gethash "label" first))))

;;; _
(provide 'herdr-session)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-session.el ends here
