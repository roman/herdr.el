;;; herdr-ui.el --- The herdr window layout  -*- lexical-binding:t -*-

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

;; The herdr layout in one command: spaces above agents down the left, and
;; a terminal filling the rest.  The panels go in side windows, so that
;; ordinary display of a file or a help buffer cannot land in one of them
;; and `delete-other-windows' in the terminal leaves the layout standing.

;; The tabs of the terminal's workspace ride on its tab line rather than
;; in a window of their own.  A window would cost a mode line and a border
;; to show one row of labels, and Emacs already puts tabs on the tab line,
;; which is where a reader looks for them.

;;; Code:

(require 'seq)
(require 'tab-line)

(require 'herdr-agents)
(require 'herdr-panel)
(require 'herdr-session)
(require 'herdr-spaces)

(declare-function herdr-term-open "herdr-term" (pane &optional writable))
(defvar herdr-term--pane)

;;; Options

(defcustom herdr-ui-side-width 32
  "Width in columns of the column holding the panels."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'natnum)

(defcustom herdr-ui-spaces-height 0.4
  "Share of the panel column given to the spaces panel.
The agents panel takes what is left."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

;;; Layout

;;;###autoload
(defun herdr-ui (&optional pane)
  "Lay out the herdr panels around the terminal for PANE.
Spaces sit above agents in a column on the left, and the terminal
fills the rest.  With no PANE, the pane the session reports as focused
is used, or the terminal already on screen.  Called interactively with
a prefix argument, PANE is read with completion."
  (interactive (list (when current-prefix-arg
                       (herdr-ui--read-pane))))
  (unless (herdr-session-live-p)
    (herdr-session-start))
  (let ((pane (or pane (herdr-panel-current-pane) (herdr-ui--focused-pane))))
    (unless pane
      (user-error "Herdr reports no pane to show"))
    (delete-other-windows)
    (herdr-panel-open-pane pane)
    (herdr-ui--display (herdr-spaces--prepare) -1 herdr-ui-spaces-height)
    (herdr-ui--display (herdr-agents--prepare) 1
                       (- 1 herdr-ui-spaces-height))
    (when-let* ((buffer (herdr-ui--terminal-buffer pane)))
      (with-current-buffer buffer
        (herdr-ui-tab-line-mode 1))
      (when-let* ((window (get-buffer-window buffer)))
        (select-window window)))))

(defun herdr-ui--display (buffer slot height)
  "Show BUFFER in the panel column, in SLOT.
HEIGHT is its share of the frame."
  (display-buffer
   buffer
   `(display-buffer-in-side-window
     (side . left)
     (slot . ,slot)
     (window-width . ,herdr-ui-side-width)
     (window-height . ,height)
     (preserve-size . (t . nil))
     ;; A panel is furniture: nothing else may be displayed over it, and
     ;; it must not be counted when Emacs looks for a window to reuse.
     (dedicated . t)
     (window-parameters . ((no-delete-other-windows . t))))))

(defun herdr-ui--terminal-buffer (pane)
  "Return the buffer mirroring PANE, or nil when there is none."
  (seq-find (lambda (buffer)
              (equal (buffer-local-value 'herdr-term--pane buffer) pane))
            (buffer-list)))

(defun herdr-ui--focused-pane ()
  "Return the pane herdr reports as focused, or nil."
  (seq-some (lambda (pane)
              (and (gethash "focused" pane) (gethash "pane_id" pane)))
            (herdr-session-panes)))

(defun herdr-ui--read-pane ()
  "Read a pane of the session with completion."
  (let ((panes (mapcar (lambda (pane) (gethash "pane_id" pane))
                       (herdr-session-panes))))
    (unless panes
      (user-error "Herdr reports no panes"))
    (completing-read "Pane: " panes nil t)))

;;;###autoload
(defun herdr-ui-quit ()
  "Take the herdr panels off the frame and stop tracking the session."
  (interactive)
  (dolist (name (list herdr-spaces-buffer-name herdr-agents-buffer-name))
    (when-let* ((buffer (get-buffer name)))
      (kill-buffer buffer)))
  (herdr-session-stop))

;;; Tab Line

(defun herdr-ui-tab-line ()
  "Return the tab line for the herdr terminal in the current buffer.
Each tab of the pane's workspace appears, the pane's own marked, and
clicking one shows a terminal for it."
  (when-let* ((pane-id (bound-and-true-p herdr-term--pane))
              (pane (herdr-session-pane pane-id))
              (tabs (herdr-session-tabs (gethash "workspace_id" pane))))
    (mapconcat (lambda (tab) (herdr-ui--tab-string tab pane))
               tabs " ")))

(defun herdr-ui--tab-string (tab pane)
  "Return the tab line entry for TAB, marked when PANE belongs to it."
  (let* ((id (gethash "tab_id" tab))
         (current (equal id (gethash "tab_id" pane)))
         (label (format " %s%s "
                        (herdr-panel-status-symbol
                         (gethash "agent_status" tab))
                        (or (gethash "label" tab) (gethash "number" tab)))))
    (propertize label
                'face (if current 'tab-line-tab-current 'tab-line-tab-inactive)
                'mouse-face 'tab-line-highlight
                'help-echo id
                'keymap (herdr-ui--tab-keymap id))))

(defun herdr-ui--tab-keymap (tab-id)
  "Return a keymap showing the first pane of TAB-ID when clicked."
  (let ((map (make-sparse-keymap)))
    (define-key map [tab-line mouse-1]
                (lambda ()
                  (interactive)
                  (herdr-ui-visit-tab tab-id)))
    map))

(defun herdr-ui-visit-tab (tab-id)
  "Show a terminal for the first pane of TAB-ID."
  (interactive (list (herdr-ui--read-tab)))
  (let ((pane (car (herdr-session-panes tab-id))))
    (unless pane
      (user-error "Tab %s has no pane" tab-id))
    (herdr-panel-open-pane (gethash "pane_id" pane))))

(defun herdr-ui--read-tab ()
  "Read a tab of the session with completion."
  (let ((tabs (mapcar (lambda (tab) (gethash "tab_id" tab))
                      (herdr-session-tabs))))
    (unless tabs
      (user-error "Herdr reports no tabs"))
    (completing-read "Tab: " tabs nil t)))

;;;###autoload
(define-minor-mode herdr-ui-tab-line-mode
  "Show the tabs of a herdr terminal's workspace on its tab line."
  :interactive nil
  (if herdr-ui-tab-line-mode
      (setq-local tab-line-format '(:eval (herdr-ui-tab-line)))
    (kill-local-variable 'tab-line-format)))

;;;###autoload
(defun herdr-ui-tab-line-setup ()
  "Turn `herdr-ui-tab-line-mode' on in every herdr terminal buffer.
Add this to `ghostel-mode-hook' to get tabs on terminals opened later."
  (when (bound-and-true-p herdr-term--pane)
    (herdr-ui-tab-line-mode 1)))

;;; _
(provide 'herdr-ui)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-ui.el ends here
