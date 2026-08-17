;;; herdr-agents.el --- The herdr agents panel  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes tools

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

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

;; Every agent herdr has detected, loudest first.  This is the panel that
;; answers "who wants me", so the order is by attention rather than by
;; position in the tree: an agent that is blocked, or that finished work
;; nobody has looked at, sorts above one that is still busy.

;; herdr reports agents only in a snapshot, never as an event, so this
;; panel redraws from `herdr-session' rather than following the wire
;; itself.

;;; Code:

(require 'magit-section)
(require 'seq)

(require 'herdr-panel)
(require 'herdr-session)

;;; Options

(defcustom herdr-agents-buffer-name "*herdr-agents*"
  "Name of the buffer showing the agents panel."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

(defcustom herdr-agents-border t
  "Whether to rule the agents panel off from the panel above it.
The two panels share a column with no mode line between them, so
without a rule they read as one list under two headings."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'boolean)

(defcustom herdr-agents-separator "›"
  "What stands between a workspace and the window inside it."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

(defcustom herdr-agents-hidden-kinds nil
  "Kinds of agent this panel leaves out.
Anything herdr reports as an agent appears here, which includes what a
tool reported about itself over the socket rather than what herdr
recognised in a pane.  A kind that has a panel of its own belongs in
that panel alone, and names itself here so that it is not listed
twice."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(repeat string))

(defface herdr-agents-claude
  '((((background dark)) :foreground "#d97757")
    (((background light)) :foreground "#c05621")
    (t :inherit font-lock-type-face))
  "Face for Claude's mark, in Claude's own orange."
  :group 'herdr-panel)

(defcustom herdr-agents-icon-faces
  '(("claude" . herdr-agents-claude))
  "Face for the mark of a kind of agent.
A kind with no face here uses `herdr-panel-agent', so an agent has to
be worth telling apart by colour before it earns one."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type string :value-type face))

(defcustom herdr-agents-icons
  '(("claude" . "✳"))
  "Glyph to show for a kind of agent, in place of its name.
A kind with no glyph here keeps its name, which says more than a
generic one would.

Nerd Fonts carries no Claude glyph, and neither does `nerd-icons';
the nearest it offers are a robot and a brain.  The default is the
mark Claude Code puts in its own terminal title, so it is Claude's
own, reads at any size and needs no particular font.  Put a private
codepoint here if your font has the real logo."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type string :value-type string))

;;; Keymaps

(defvar-keymap herdr-agents-mode-map
  :doc "Keymap for `herdr-agents-mode'."
  :parent herdr-panel-mode-map)

(with-eval-after-load 'evil
  (herdr-panel-install-evil-keys herdr-agents-mode-map))

;;; Mode

(define-derived-mode herdr-agents-mode magit-section-mode "Herdr Agents"
  "Major mode for the herdr agents panel."
  :interactive nil
  (herdr-panel-init #'herdr-agents-refresh #'herdr-agents--pane-at-point))

;;; Commands

;;;###autoload
(defun herdr-agents ()
  "Show the panel listing the agents herdr has detected."
  (interactive)
  (pop-to-buffer (herdr-agents-panel)))

(defun herdr-agents-panel ()
  "Return the agents buffer, drawn and tracking the session.
Separate from `herdr-agents' so that a caller arranging its own
windows does not have to undo a `pop-to-buffer' first.  This is the
form `herdr-ui-panels' names to put the panel in a column."
  (let ((buffer (get-buffer-create herdr-agents-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-agents-mode)
        (herdr-agents-mode))
      (herdr-panel-watch)
      (herdr-agents-refresh))
    buffer))

;;;###autoload
(defun herdr-agents-visit (pane &optional other)
  "Show the terminal for the agent called PANE.
PANE is read with completion over the agents herdr has detected, the
ones wanting attention first, exactly as the panel lists them.  With a
prefix argument OTHER, open it the other way round from
`herdr-panel-visit-access', as pressing RET on the row would."
  (interactive (list (herdr-agents--read) current-prefix-arg))
  (herdr-panel-open-pane pane (herdr-panel-access other)))

(defun herdr-agents--read ()
  "Read an agent with completion and return its pane."
  (herdr-panel-ensure-session)
  (let ((agents (herdr-agents--sorted))
        (current (herdr-panel-current-pane)))
    (unless agents
      (user-error "Herdr has detected no agents"))
    (herdr-panel-read-pane
     "Agent: "
     (mapcar (lambda (agent)
               (cons (herdr-panel-entry-line
                      (herdr-agents--entry agent current))
                     (gethash "pane_id" agent)))
             agents))))

(defun herdr-agents-refresh ()
  "Redraw the agents panel from the session tree."
  (interactive)
  (with-current-buffer (get-buffer-create herdr-agents-buffer-name)
    (herdr-panel-with-redraw
      (magit-insert-section (herdr-agents-root)
        (herdr-panel-insert-title
         "Agents" (and herdr-agents-border 'herdr-panel-border))
        (let ((agents (herdr-agents--sorted))
              (current (herdr-panel-current-pane)))
          (if agents
              (dolist (agent agents)
                (herdr-agents--insert agent current))
            (insert (propertize "  no agents detected\n"
                                'face 'herdr-panel-unknown))))))
    (herdr-panel-settle-point)))

;;; Rendering

(defun herdr-agents--sorted ()
  "Return the agents to list, the ones wanting attention first.
Ties keep herdr's own order, so the list does not shuffle while
several agents share a status.  Kinds in `herdr-agents-hidden-kinds'
are left out."
  (seq-sort-by (lambda (agent)
                 (herdr-session-status-priority
                  (herdr-session-status agent)))
               #'>
               (seq-remove (lambda (agent)
                             (member (gethash "agent" agent)
                                     herdr-agents-hidden-kinds))
                           (herdr-session-agents))))

(defun herdr-agents--entry (agent current)
  "Return the row for AGENT, emphasised against the CURRENT pane.
Which workspace and window an agent sits in is what tells two agents
of the same kind apart, so that names the row and the kind follows it
rather than the other way round."
  (list :status (herdr-session-status agent)
        :emphasis (herdr-panel-emphasis (gethash "pane_id" agent) current)
        :id (gethash "pane_id" agent)
        :label (herdr-agents--where agent)
        :aside (herdr-agents--kind agent)
        :detail (herdr-agents--detail agent)))

(defun herdr-agents--insert (agent current)
  "Insert an entry for AGENT, emphasised against the CURRENT pane."
  (magit-insert-section (herdr-agent (gethash "pane_id" agent))
    (herdr-panel-insert-entry (herdr-agents--entry agent current))))

(defun herdr-agents--where (agent)
  "Return where AGENT is: its workspace, and its window within it.
The window is left out when the workspace holds only one, where it
would be a number that never changes and never distinguishes."
  (let* ((name (herdr-agents--workspace-name agent))
         (tab (herdr-agents--tab agent)))
    (if tab
        (concat name
                (herdr-panel-text (concat " " herdr-agents-separator " ")
                                  'herdr-panel-separator)
                (herdr-panel-text tab 'herdr-panel-window))
      name)))

(defun herdr-agents--workspace-name (agent)
  "Return the workspace name for AGENT."
  (let ((workspace
         (herdr-session-workspace (gethash "workspace_id" agent))))
    (if workspace
        (gethash "label" workspace)
      (gethash "workspace_id" agent))))

(defun herdr-agents--tab (agent)
  "Return the name of the window AGENT sits in, or nil when it is alone."
  (let ((tabs (herdr-session-tabs (gethash "workspace_id" agent))))
    (when (cdr tabs)
      (when-let* ((tab (seq-find (lambda (tab)
                                   (equal (gethash "tab_id" tab)
                                          (gethash "tab_id" agent)))
                                 tabs)))
        (or (gethash "label" tab)
            (number-to-string (gethash "number" tab)))))))

(defun herdr-agents--kind (agent)
  "Return what kind of agent AGENT is, as a glyph or as a name.
See `herdr-agents-icons' for which kinds have a glyph."
  (when-let* ((kind (or (gethash "agent" agent)
                        (gethash "display_agent" agent))))
    (herdr-panel-text (or (cdr (assoc kind herdr-agents-icons)) kind)
                      (or (cdr (assoc kind herdr-agents-icon-faces))
                          'herdr-panel-agent))))

(defun herdr-agents--detail (agent)
  "Return AGENT's title unless it repeats the workspace name."
  (let ((title (herdr-session-agent-title agent)))
    (unless (equal title (herdr-agents--workspace-name agent))
      title)))

(defun herdr-agents--pane-at-point ()
  "Return the pane of the row at point, or signal when there is none."
  (let ((section (magit-current-section)))
    (or (and section
             (eq (oref section type) 'herdr-agent)
             (oref section value))
        (user-error "No agent at point"))))

;;; _
(provide 'herdr-agents)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-agents.el ends here
