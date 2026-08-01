;;; herdr-spaces.el --- The herdr spaces panel  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>
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

;; The workspaces of the session, grouped the way herdr groups them: the
;; checkouts of one repository share a space, and the space carries the
;; loudest state among them.  A space of one workspace is drawn as that
;; workspace, with no group to expand, which is what herdr does with an
;; ungrouped checkout.

;; Grouping is `herdr-session-spaces'.  It lives there rather than here
;; because it is a fact about the session, not about how a panel draws it.

;;; Code:

(require 'magit-section)
(require 'seq)

(require 'herdr-panel)
(require 'herdr-session)

;;; Options

(defcustom herdr-spaces-buffer-name "*herdr-spaces*"
  "Name of the buffer showing the spaces panel."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

;;; Keymaps

(defvar-keymap herdr-spaces-mode-map
  :doc "Keymap for `herdr-spaces-mode'."
  :parent herdr-panel-mode-map)

(with-eval-after-load 'evil
  (herdr-panel-install-evil-keys herdr-spaces-mode-map))

;;; Mode

(define-derived-mode herdr-spaces-mode magit-section-mode "Herdr Spaces"
  "Major mode for the herdr spaces panel."
  :interactive nil
  (herdr-panel-init #'herdr-spaces-refresh #'herdr-spaces--pane-at-point))

;;; Commands

;;;###autoload
(defun herdr-spaces ()
  "Show the panel listing the spaces of the herdr session."
  (interactive)
  (pop-to-buffer (herdr-spaces--prepare)))

(defun herdr-spaces--prepare ()
  "Return the spaces buffer, drawn and tracking the session.
Separate from `herdr-spaces' so that a caller arranging its own
windows does not have to undo a `pop-to-buffer' first."
  (let ((buffer (get-buffer-create herdr-spaces-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-spaces-mode)
        (herdr-spaces-mode))
      (herdr-panel-watch)
      (herdr-spaces-refresh))
    buffer))

(defun herdr-spaces-refresh ()
  "Redraw the spaces panel from the session tree."
  (interactive)
  (with-current-buffer (get-buffer-create herdr-spaces-buffer-name)
    (herdr-panel-with-redraw
      (magit-insert-section (herdr-spaces-root)
        (magit-insert-heading "Spaces")
        (let ((spaces (herdr-session-spaces))
              (current (herdr-spaces--current-workspace)))
          (if spaces
              (dolist (space spaces)
                (herdr-spaces--insert space current))
            (insert (propertize "  no spaces\n"
                                'face 'herdr-panel-unknown))))))
    (herdr-panel-settle-point)))

;;; Rendering

(defun herdr-spaces--current-workspace ()
  "Return the workspace holding the pane mirrored by the selected window."
  (when-let* ((pane-id (herdr-panel-current-pane))
              (pane (herdr-session-pane pane-id)))
    (gethash "workspace_id" pane)))

(defun herdr-spaces--insert (space current)
  "Insert SPACE, marking the workspace CURRENT wherever it appears.
A space of one workspace is drawn as that workspace: giving it a group
to expand would put every ungrouped checkout behind a heading that
holds a single child."
  (let ((workspaces (plist-get space :workspaces)))
    (if (cdr workspaces)
        (magit-insert-section (herdr-space (plist-get space :key))
          (magit-insert-heading
            (concat " " (herdr-panel-status-string
                         (plist-get space :agent-status))
                    " " (herdr-panel--propertize (plist-get space :label)
                                                 'magit-section-heading)))
          (dolist (workspace workspaces)
            (herdr-spaces--insert-workspace workspace current t)))
      (herdr-spaces--insert-workspace (car workspaces) current nil))))

(defun herdr-spaces--insert-workspace (workspace current indented)
  "Insert WORKSPACE, emphasised against CURRENT and INDENTED under a space."
  (let ((id (gethash "workspace_id" workspace)))
    (magit-insert-section (herdr-workspace id)
      (herdr-panel-insert-row (gethash "agent_status" workspace)
                              (gethash "label" workspace)
                              (herdr-spaces--emphasis id current)
                              (herdr-spaces--branch workspace)
                              (if indented "   " " ")))))

(defun herdr-spaces--emphasis (workspace-id current)
  "Return how to draw WORKSPACE-ID, given the CURRENT workspace.
A workspace counts as open when any one of its panes is: it is the
workspace the row stands for, not a particular pane of it."
  (cond ((equal workspace-id current) 'current)
        ((seq-some (lambda (pane)
                     (and (equal (gethash "workspace_id" pane) workspace-id)
                          (herdr-panel-pane-open-p (gethash "pane_id" pane))))
                   (herdr-session-panes))
         'open)
        (t 'closed)))

(defun herdr-spaces--branch (workspace)
  "Return the checkout WORKSPACE sits on, or nil when it is not a worktree.
herdr shows this beside a grouped workspace, where the label alone
would not say which checkout of the repository a row is."
  (when-let* ((worktree (gethash "worktree" workspace))
              ((gethash "is_linked_worktree" worktree)))
    (file-name-nondirectory
     (directory-file-name (gethash "checkout_path" worktree)))))

(defun herdr-spaces--pane-at-point ()
  "Return a pane to visit for the row at point.
A workspace offers the pane of its active tab, which is the one herdr
shows when that workspace is focused.  A space offers the same for its
first member, so that a group heading leads somewhere rather than
refusing."
  (let* ((section (magit-current-section))
         (type (and section (oref section type)))
         (value (and section (oref section value)))
         (workspace (pcase type
                      ('herdr-workspace (herdr-session-workspace value))
                      ('herdr-space (car (herdr-spaces--members value))))))
    (unless workspace
      (user-error "No workspace at point"))
    (let* ((tab (gethash "active_tab_id" workspace))
           (pane (car (herdr-session-panes tab))))
      (unless pane
        (user-error "Workspace %s has no pane"
                    (gethash "workspace_id" workspace)))
      (gethash "pane_id" pane))))

(defun herdr-spaces--members (key)
  "Return the workspaces of the space called KEY."
  (plist-get (seq-find (lambda (space) (equal (plist-get space :key) key))
                       (herdr-session-spaces))
             :workspaces))

;;; _
(provide 'herdr-spaces)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-spaces.el ends here
