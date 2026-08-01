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

(defcustom herdr-spaces-separator "·"
  "What stands between the notes on a workspace's second line."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

(defcustom herdr-spaces-git t
  "Whether to show the branch and working tree state of a workspace.
This runs git once per workspace per `herdr-spaces-git-ttl', which on
a very large repository is worth knowing about."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'boolean)

(defcustom herdr-spaces-git-ttl 5
  "Seconds an answer from git is reused before asking again."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

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
  (herdr-panel-init #'herdr-spaces-refresh #'herdr-spaces--pane-at-point)
  ;; Nothing on the wire says a branch changed, so the panel has to say
  ;; so itself or a checkout would sit stale until something else moved.
  (add-hook 'herdr-session-fingerprint-functions #'herdr-spaces--git-marks))

(defun herdr-spaces--git-marks ()
  "Return the git state of every workspace, for the session fingerprint."
  (and herdr-spaces-git
       (mapcar (lambda (workspace)
                 (herdr-spaces--git (herdr-spaces--directory workspace)))
               (herdr-session-workspaces))))

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

;;; Git

;; herdr shows a branch and a git status on a space, and computes both
;; itself, but puts neither on the wire for a workspace that is not a
;; worktree.  We know the directory, so we ask git here instead.  One
;; `status' call answers all three questions at once, and its answer is
;; cached, because a redraw must never cost a subprocess per workspace.

(defvar herdr-spaces--git-cache (make-hash-table :test #'equal)
  "Cached git answers, keyed by directory.
Each value has the form (WHEN . DESCRIPTION).")

(defun herdr-spaces--git (directory)
  "Return a short description of DIRECTORY's git state, or nil."
  (when (and herdr-spaces-git directory (file-directory-p directory))
    (let ((cached (gethash directory herdr-spaces--git-cache)))
      (if (and cached (< (- (float-time) (car cached)) herdr-spaces-git-ttl))
          (cdr cached)
        (let ((description (herdr-spaces--git-ask directory)))
          (puthash directory (cons (float-time) description)
                   herdr-spaces--git-cache)
          description)))))

(defun herdr-spaces--git-ask (directory)
  "Ask git about DIRECTORY and return a description, or nil.
Untracked files are excluded, which is what keeps this quick on a
large repository and is rarely what the count is wanted for."
  (with-temp-buffer
    (let ((status (ignore-errors
                    (call-process "git" nil (list t nil) nil
                                  "-C" directory "status"
                                  "--porcelain=v2" "--branch" "-uno"))))
      (when (eql status 0)
        (herdr-spaces--git-describe (buffer-string))))))

(defun herdr-spaces--git-describe (output)
  "Return a description of git status OUTPUT, or nil when it has none."
  (let (branch ahead behind (changed 0))
    (dolist (line (split-string output "\n" t))
      (cond
        ((string-prefix-p "# branch.head " line)
         (setq branch (substring line (length "# branch.head "))))
        ((string-prefix-p "# branch.ab " line)
         (pcase-let ((`(,a ,b) (split-string
                                (substring line (length "# branch.ab ")))))
           (setq ahead (string-to-number a)
                 behind (abs (string-to-number b)))))
        ((not (string-prefix-p "#" line))
         (setq changed (1+ changed)))))
    (when (and branch (not (equal branch "(detached)")))
      (string-join
       (delq nil
             (list (herdr-panel-text branch 'herdr-panel-branch)
                   (and ahead (> ahead 0)
                        (herdr-panel-text (format "↑%d" ahead)
                                          'herdr-panel-ahead))
                   (and behind (> behind 0)
                        (herdr-panel-text (format "↓%d" behind)
                                          'herdr-panel-behind))
                   (and (> changed 0)
                        (herdr-panel-text (format "*%d" changed)
                                          'herdr-panel-dirty))))
       " "))))

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
      (herdr-panel-insert-entry
       (list :status (gethash "agent_status" workspace)
             :emphasis (herdr-spaces--emphasis id current)
             :label (gethash "label" workspace)
             :detail (herdr-spaces--detail workspace)
             :indent (if indented "   " " "))))))

(defun herdr-spaces--detail (workspace)
  "Return the lines that follow WORKSPACE's name.
Where it sits, then what git makes of it.  The directory is where the
name comes from and what tells two checkouts of the same basename
apart; the branch and the counts are what herdr shows on a space and
does not put on the wire."
  (let* ((directory (herdr-spaces--directory workspace))
         (separator (herdr-panel-text (concat " " herdr-spaces-separator " ")
                                      'herdr-panel-separator)))
    (list (string-join
           (delq nil
                 (list (and directory
                            (herdr-panel-text (abbreviate-file-name directory)
                                              'herdr-panel-path))
                       (herdr-spaces--windows workspace)))
           separator)
          (string-join
           (delq nil (list (herdr-spaces--git directory)
                           (herdr-spaces--branch workspace)))
           separator))))

(defun herdr-spaces--directory (workspace)
  "Return the directory WORKSPACE's root pane sits in, or nil."
  (when-let* ((tab (gethash "active_tab_id" workspace))
              (pane (car (herdr-session-panes tab))))
    (gethash "cwd" pane)))

(defun herdr-spaces--windows (workspace)
  "Return the window count of WORKSPACE, or nil when it is one.
A count of one is what every workspace starts with and so says
nothing."
  (let ((tabs (gethash "tab_count" workspace)))
    (and tabs (> tabs 1)
         (herdr-panel-text (format "%d windows" tabs) 'herdr-panel-window))))

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
    (herdr-panel-text
     (file-name-nondirectory
      (directory-file-name (gethash "checkout_path" worktree)))
     'herdr-panel-path)))

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
