;;; herdr-agents.el --- The herdr agents panel  -*- lexical-binding:t -*-

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

;;; Keymaps

(defvar-keymap herdr-agents-mode-map
  :doc "Keymap for `herdr-agents-mode'."
  :parent magit-section-mode-map
  "RET" #'herdr-agents-visit
  "g" #'herdr-agents-refresh)

;;; Mode

(define-derived-mode herdr-agents-mode magit-section-mode "Herdr Agents"
  "Major mode for the herdr agents panel."
  :interactive nil
  (setq herdr-panel-refresh-function #'herdr-agents-refresh)
  (add-hook 'kill-buffer-hook #'herdr-panel-unwatch nil t))

;;; Commands

;;;###autoload
(defun herdr-agents ()
  "Show the panel listing the agents herdr has detected."
  (interactive)
  (pop-to-buffer (herdr-agents--prepare)))

(defun herdr-agents--prepare ()
  "Return the agents buffer, drawn and tracking the session.
Separate from `herdr-agents' so that a caller arranging its own
windows does not have to undo a `pop-to-buffer' first."
  (let ((buffer (get-buffer-create herdr-agents-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-agents-mode)
        (herdr-agents-mode))
      (herdr-panel-watch)
      (herdr-agents-refresh))
    buffer))

(defun herdr-agents-refresh ()
  "Redraw the agents panel from the session tree."
  (interactive)
  (with-current-buffer (get-buffer-create herdr-agents-buffer-name)
    (herdr-panel-with-redraw
      (magit-insert-section (herdr-agents-root)
        (magit-insert-heading "Agents")
        (let ((agents (herdr-agents--sorted))
              (current (herdr-panel-current-pane)))
          (if agents
              (dolist (agent agents)
                (herdr-agents--insert agent current))
            (insert (propertize "  no agents detected\n"
                                'face 'herdr-panel-unknown))))))))

(defun herdr-agents-visit ()
  "Show the terminal of the agent at point."
  (interactive)
  (herdr-panel-open-pane (herdr-agents--pane-at-point)))

;;; Rendering

(defun herdr-agents--sorted ()
  "Return the agents, the ones wanting attention first.
Ties keep herdr's own order, so the list does not shuffle while
several agents share a status."
  (seq-sort-by (lambda (agent)
                 (herdr-session-status-priority
                  (gethash "agent_status" agent)))
               #'>
               (herdr-session-agents)))

(defun herdr-agents--insert (agent current)
  "Insert a row for AGENT, marked when its pane is CURRENT."
  (let* ((pane (gethash "pane_id" agent))
         (status (gethash "agent_status" agent))
         (start (point)))
    (magit-insert-section (herdr-agent pane)
      (insert " " (herdr-panel-status-string status) " "
              (propertize (herdr-agents--name agent)
                          'face (herdr-panel-status-face status))
              "  "
              (propertize (or (gethash "terminal_title_stripped" agent) "")
                          'face 'herdr-panel-idle)
              "\n")
      (when (equal pane current)
        (put-text-property start (point) 'face 'herdr-panel-current)))))

(defun herdr-agents--name (agent)
  "Return what to call AGENT.
A name the user gave it wins, then the kind herdr chose to display,
then the kind it detected, and failing all of those its pane."
  (or (gethash "name" agent)
      (gethash "display_agent" agent)
      (gethash "agent" agent)
      (gethash "pane_id" agent)))

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
