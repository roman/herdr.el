;;; herdr-session.el --- Track the herdr session tree  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>
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

(require 'json)
(require 'seq)
(require 'subr-x)

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

(defcustom herdr-session-poll-interval 5
  "Seconds between snapshots taken without an event asking for one.
Some of what the panels show changes with no event to announce it.  A
workspace label is derived from the working directory of its root
pane, and a shell changing directory reports nothing at all: herdr
recomputes the label, and a client listening only to events goes on
showing the old one for as long as the session lasts.

The cost of the poll is one short connection, and a snapshot that
changes nothing visible is dropped before any panel redraws, so a
quiet session costs nothing but the request.  Set this to nil to
listen to events alone."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-session
  :type '(choice (const :tag "Do not poll" nil) number))

(defcustom herdr-session-codex-index-file
  (expand-file-name
   "session_index.jsonl"
   (expand-file-name (or (getenv "CODEX_HOME") "~/.codex")))
  "File where Codex records session names set by `/rename'.
The agent snapshot identifies a Codex session but does not carry this
name, so the session model joins the two by identifier.  Nil disables
the lookup.  Changes are noticed by the ordinary session poll."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-session
  :type '(choice (const :tag "Do not read Codex session names" nil)
                 file))

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

(defvar herdr-session-fingerprint-functions nil
  "Functions returning extra values that should provoke a redraw.
A panel adds to this when it shows something the session tree does not
carry.  A git branch is the example: herdr computes one but puts it on
the wire for no workspace that is not a worktree, so a client that
reads it locally has to say when it changed, or the change waits for
something else to move.")

(defvar herdr-session-change-hook nil
  "Hook run after the session tree changed.
Consumers add themselves here to update from the new tree.  It runs
outside any process filter, so a function on it may call the herdr
API.")

(defvar herdr-session--snapshot nil
  "The last snapshot hash-table, or nil before the first refresh.")

(defvar herdr-session--fingerprint nil
  "Fingerprint of the last snapshot consumers were told about.")

(defvar herdr-session--subscription nil
  "Process carrying the event subscription, or nil when stopped.")

(defvar herdr-session--timer nil
  "Timer of a pending refresh, or nil when none is due.")

(defvar herdr-session--poll-timer nil
  "Repeating timer taking the snapshots no event asks for.")

(defvar herdr-session--closed-reason nil
  "Why the event subscription ended, or nil while it is healthy.")

(defvar herdr-session--codex-index-cache nil
  "Cached Codex names as (FILE MODIFICATION-TIME NAMES).
NAMES is a hash table keyed by Codex session identifier.")

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
  (when herdr-session-poll-interval
    (setq herdr-session--poll-timer
          (run-at-time herdr-session-poll-interval
                       herdr-session-poll-interval
                       #'herdr-session--refresh-quietly)))
  herdr-session--subscription)

;;;###autoload
(defun herdr-session-stop ()
  "Stop tracking the session tree and forget it."
  (interactive)
  (dolist (timer (list herdr-session--timer herdr-session--poll-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq herdr-session--timer nil
        herdr-session--poll-timer nil)
  (herdr-api-unsubscribe herdr-session--subscription)
  (setq herdr-session--subscription nil))

(defun herdr-session-live-p ()
  "Return non-nil while the session tree is being kept current."
  (process-live-p herdr-session--subscription))

(defun herdr-session-refresh (&optional force)
  "Replace the session tree with a fresh snapshot, then announce it.
The announcement is skipped when no consumed field has changed,
unless FORCE says otherwise.  A pane running an agent reports an event
several times a second, and updating every consumer that often is work
no one sees.

This blocks, so it must not run from a process filter; see
`herdr-session--note-event'."
  (interactive "p")
  (setq herdr-session--snapshot
        (gethash "snapshot" (herdr-api-request "session.snapshot")))
  (herdr-session--note-finishes)
  (let ((fingerprint (herdr-session--fingerprint)))
    (when (or force (not (equal fingerprint herdr-session--fingerprint)))
      (setq herdr-session--fingerprint fingerprint)
      (run-hooks 'herdr-session-change-hook)))
  herdr-session--snapshot)

(defun herdr-session--fingerprint ()
  "Return the user-visible tree state as a value that can be compared.
Only fields consumed by a panel or terminal buffer take part, so the
churn of revisions and scroll positions does not count as a change."
  (list (mapcar (lambda (workspace)
                  (list (gethash "workspace_id" workspace)
                        (gethash "label" workspace)
                        (herdr-session-status workspace)
                        (gethash "focused" workspace)
                        (herdr-session-space-key workspace)))
                (herdr-session-workspaces))
        (mapcar (lambda (tab)
                  (list (gethash "tab_id" tab)
                        (gethash "label" tab)
                        (herdr-session-status tab)
                        (gethash "focused" tab)))
                (herdr-session-tabs))
        (mapcar (lambda (agent)
                  (list (gethash "pane_id" agent)
                        (gethash "agent" agent)
                        (herdr-session-status agent)
                        (herdr-session-agent-title agent)
                        (gethash "focused" agent)))
                (herdr-session-agents))
        (mapcar (lambda (pane)
                  (list (gethash "pane_id" pane)
                        (herdr-session-status pane)
                        (gethash "focused" pane)
                        (gethash "cwd" pane)))
                (herdr-session-panes))
        (mapcar #'funcall herdr-session-fingerprint-functions)))

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
  (herdr-session--refresh-quietly))

(defun herdr-session--refresh-quietly ()
  "Refresh, keeping a failure from stopping the timer that asked.
A server that went away must not leave a repeating timer signalling
once an interval for as long as Emacs runs."
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

(defun herdr-session-agent-title (agent)
  "Return the user-facing title of AGENT, or nil.
A name assigned through herdr wins.  Codex names are joined from its
local session index because its terminal title only reports the
project.  Other agents use their stripped terminal title."
  (let ((pane (gethash "pane_id" agent))
        (name (gethash "name" agent)))
    (or (and (stringp name)
             (not (string-empty-p name))
             (not (equal name pane))
             name)
        (herdr-session--codex-title agent)
        (when-let* ((title (gethash "terminal_title_stripped" agent))
                    ((stringp title))
                    ((not (string-empty-p title))))
          title))))

(defun herdr-session--codex-title (agent)
  "Return AGENT's Codex session title, or nil."
  (when (equal (gethash "agent" agent) "codex")
    (when-let* ((session (gethash "agent_session" agent))
                ((hash-table-p session))
                (id (gethash "value" session))
                ((stringp id)))
      (gethash id (herdr-session--codex-index)))))

(defun herdr-session--codex-index ()
  "Return Codex session names keyed by identifier.
Cache the parsed index until its modification time or configured path
changes.  A missing or unreadable index is an empty one because Codex
is an optional peer, not a requirement of the session model."
  (let* ((file herdr-session-codex-index-file)
         (attributes (and file
                          (file-readable-p file)
                          (file-attributes file 'string)))
         (modified (and attributes
                        (file-attribute-modification-time attributes))))
    (unless (and herdr-session--codex-index-cache
                 (equal file (nth 0 herdr-session--codex-index-cache))
                 (equal modified
                        (nth 1 herdr-session--codex-index-cache)))
      (setq herdr-session--codex-index-cache
            (list file modified
                  (if modified
                      (herdr-session--read-codex-index file)
                    (make-hash-table :test #'equal)))))
    (nth 2 herdr-session--codex-index-cache)))

(defun herdr-session--read-codex-index (file)
  "Return the session names recorded in Codex index FILE.
Malformed lines are ignored so that one interrupted write does not
make every agent lose its fallback title."
  (let ((names (make-hash-table :test #'equal)))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (unless (string-empty-p line)
                (condition-case nil
                    (let ((entry (json-parse-string line)))
                      (when (hash-table-p entry)
                        (when-let* ((id (gethash "id" entry))
                                    (name (gethash "thread_name" entry))
                                    ((stringp id))
                                    ((stringp name))
                                    ((not (string-empty-p name))))
                          (puthash id name names))))
                  (json-parse-error nil))))
            (forward-line 1)))
      (file-error nil))
    names))

(defun herdr-session-workspace (workspace-id)
  "Return the workspace called WORKSPACE-ID, or nil."
  (seq-find (lambda (workspace)
              (equal (gethash "workspace_id" workspace) workspace-id))
            (herdr-session-workspaces)))

(defun herdr-session-protocol ()
  "Return the protocol version herdr reported, or nil."
  (and herdr-session--snapshot
       (gethash "protocol" herdr-session--snapshot)))

;;; Finishes This Emacs Has Not Seen

;; herdr reports "done" for a finish it holds the operator not to have
;; watched, and "idle" for one it holds them to have seen.  It writes that
;; from whether the pane is its own workspace's active tab and whether the
;; terminal running herdr holds focus, and a workspace of one tab, read
;; from that terminal, leaves both true for good.  Such a session reports
;; "done" never, and every reader of the status that exists to catch a
;; finish catches nothing.

;; So the question can be answered here instead.  A pane that leaves a
;; running state for a resting one is marked, and stays marked until it
;; runs again or is read.  Nothing else moves the mark: whether the pane
;; is on screen is the guess that fails, because in the herdr layout it
;; almost always is.

;; What is marked is reported as "done" rather than kept beside the
;; status, so that everything already written against the status agrees
;; without being told: the mark, its colour, the row fill, the sort order,
;; and the rollups a space and a tab show.

(defcustom herdr-session-finish-seen-by 'herdr
  "Who decides whether a finish has been seen.
`herdr' takes herdr's word for it.  A finish arrives as \"done\" while
herdr holds it unread and as \"idle\" once it does not, and this Emacs
passes both on unchanged.

`emacs' answers here instead.  A pane that stops running is reported
as \"done\" until it runs again or `herdr-session-mark-seen' is called
on it, whatever herdr made of the same finish.  Worth setting where
herdr's answer is always \"seen\", which a workspace of one tab read
from the terminal running herdr always is."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-session
  :type '(choice (const :tag "herdr" herdr)
                 (const :tag "This Emacs" emacs)))

(defconst herdr-session-running-statuses '("working" "blocked")
  "The statuses a pane is doing something in.
Leaving one of these for anything else is a finish.  Blocked counts as
running because the agent is still in the middle of its work; what it
wants is answered by the request sound rather than by a finish.")

(defvar herdr-session--reported (make-hash-table :test #'equal)
  "The status herdr last reported for each pane, keyed by pane id.
A pane absent from this has never been seen, and its first status is
no transition: without that, every agent resting when Emacs connected
would be marked at once.")

(defvar herdr-session--unread (make-hash-table :test #'equal)
  "Panes whose finish has not been read, keyed by pane id.
Only the keys carry meaning.  Empty while
`herdr-session-finish-seen-by' is `herdr', which is what makes the
option cost nothing when it is off.")

(defun herdr-session-unread-p (pane-id)
  "Return non-nil when PANE-ID finished and nobody has read it."
  (and (gethash pane-id herdr-session--unread) t))

(defun herdr-session-mark-seen (pane-id)
  "Record that the finish on PANE-ID has been read.
Call this where the user goes to a pane deliberately.  Returns non-nil
when there was a mark to clear, so that a caller can redraw only when
something changed."
  (when (gethash pane-id herdr-session--unread)
    (remhash pane-id herdr-session--unread)
    t))

(defun herdr-session--note-finishes ()
  "Mark every pane that has just stopped running, and unmark the rest.
Called with a fresh tree in hand and before the fingerprint is taken,
so that a mark appearing or going counts as a change worth redrawing."
  (let ((reported (make-hash-table :test #'equal)))
    (dolist (agent (herdr-session-agents))
      (let* ((pane (gethash "pane_id" agent))
             (status (gethash "agent_status" agent))
             (previous (gethash pane herdr-session--reported)))
        (puthash pane status reported)
        (cond
          ((not (eq herdr-session-finish-seen-by 'emacs)))
          ((member status herdr-session-running-statuses)
           (remhash pane herdr-session--unread))
          ((member previous herdr-session-running-statuses)
           (puthash pane t herdr-session--unread)))))
    ;; A pane herdr no longer reports keeps no mark, or the table grows
    ;; for as long as Emacs runs and raises whatever reuses its name.
    (maphash (lambda (pane _)
               (unless (gethash pane reported)
                 (remhash pane herdr-session--unread)))
             (copy-hash-table herdr-session--unread))
    (setq herdr-session--reported reported)))

(defun herdr-session-status (node)
  "Return the agent status to show for NODE, which is any tree node.
This is what herdr reported, except that an idle row covering a pane
whose finish nobody has read reads \"done\" instead.  Only an idle row
is raised: one herdr calls working has something running in it, and
calling that finished would be false as well as quieter."
  (let ((status (gethash "agent_status" node)))
    (if (and (equal status "idle") (herdr-session--unread-node-p node))
        "done"
      status)))

(defun herdr-session--unread-node-p (node)
  "Return non-nil when NODE covers a pane whose finish is unread.
A pane answers for itself, and a tab or a workspace answers for the
panes inside it, which is the rollup herdr does for the status."
  (cond
    ((gethash "pane_id" node)
     (herdr-session-unread-p (gethash "pane_id" node)))
    ((gethash "tab_id" node)
     (herdr-session--unread-under "tab_id" (gethash "tab_id" node)))
    ((gethash "workspace_id" node)
     (herdr-session--unread-under "workspace_id"
                                  (gethash "workspace_id" node)))))

(defun herdr-session--unread-under (key value)
  "Return non-nil when an agent whose KEY is VALUE has an unread finish."
  (seq-some (lambda (agent)
              (and (equal (gethash key agent) value)
                   (herdr-session-unread-p (gethash "pane_id" agent))))
            (herdr-session-agents)))

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
                       (mapcar #'herdr-session-status workspaces)))))
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
