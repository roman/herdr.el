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
(declare-function herdr-term-fit-to-window "herdr-term" ())
(defvar herdr-term--pane)
(defvar herdr-term-command-mode-map)

;;; Keys

;; Reachable from either side of the layout, because the column is as
;; often in the way of a terminal as it is of itself.  `C-c' is already
;; the prefix a herdr buffer answers on, and evil binds it in neither
;; normal nor insert state, so this works with evil and without it.
(keymap-set herdr-panel-mode-map "C-c C-b" #'herdr-ui-toggle-panels)

(with-eval-after-load 'herdr-term
  (keymap-set herdr-term-command-mode-map "C-c C-b"
              #'herdr-ui-toggle-panels))

;;; Options

(defcustom herdr-ui-side-width 32
  "Width in columns of the column holding the panels."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'natnum)

(defcustom herdr-ui-spaces-height 0.6
  "Share of the panel column given to the spaces panel.
The agents panel takes what is left.  Spaces gets the larger share
because it lists every workspace, while agents lists only the panes
herdr found one running in."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

(defcustom herdr-ui-tame-window-packages t
  "Whether to ask window-managing packages to leave the layout alone.
Packages that resize or fade windows behind your back fight a fixed
layout.  golden-ratio regrows whichever window you select, so a panel
changes width as you move through it and the terminal shrinks the
moment you leave it.  dimmer fades every window but the selected one,
so reading the terminal greys out the panels that exist to be glanced
at, and touching a panel greys out the terminal.

Only the herdr windows are exempted, and only while the layout is on
the frame, so both packages behave as they always did everywhere else.
Set this to nil to leave their settings untouched."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'boolean)

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
  (when herdr-ui-tame-window-packages
    (herdr-ui--tame))
  (let ((pane (or pane (herdr-panel-current-pane) (herdr-ui--focused-pane))))
    (unless pane
      (user-error "Herdr reports no pane to show"))
    ;; Before `delete-other-windows', which refuses to leave a side
    ;; window alone on a frame, and because a side window that survives
    ;; is reused at whatever width it drifted to rather than at the one
    ;; asked for here.
    (herdr-ui--clear)
    (delete-other-windows)
    ;; With control, because this is the terminal the layout is built
    ;; around and one that ignored what was typed at it would be a
    ;; puzzle rather than a terminal.  A panel visiting a row still
    ;; observes; only one client at a time may hold a pane.
    (herdr-panel-open-pane pane 'control)
    (herdr-ui--show-panels)
    (when-let* ((buffer (herdr-ui--terminal-buffer pane)))
      (with-current-buffer buffer
        (herdr-ui-tab-line-mode 1))
      (when-let* ((window (get-buffer-window buffer)))
        (select-window window)))))

;;;###autoload
(defun herdr-ui-toggle-panels ()
  "Show or hide the column of panels.
Hiding takes the windows off the frame and leaves the panels
themselves alone, still reading the session, so showing them again
costs nothing and shows the present rather than the past."
  (interactive)
  (if (herdr-ui-panels-visible-p)
      (herdr-ui--clear)
    (unless (herdr-session-live-p)
      (herdr-session-start))
    (when herdr-ui-tame-window-packages
      (herdr-ui--tame))
    (herdr-ui--show-panels))
  (herdr-ui--refit-terminals))

(defun herdr-ui--refit-terminals (&optional frame)
  "Ask every herdr terminal on FRAME to fit the window it now has.
Said rather than left to be noticed: the hook that notices a window
resizing runs from redisplay, and a layout rearranged by a command
does not always reach it, which leaves a terminal drawing into a
fraction of the width it was just given."
  (when (fboundp 'herdr-term-fit-to-window)
    (dolist (window (window-list frame))
      (let ((buffer (window-buffer window)))
        (when (buffer-local-value 'herdr-term--pane buffer)
          (with-current-buffer buffer
            (herdr-term-fit-to-window)))))))

(defun herdr-ui-panels-visible-p (&optional frame)
  "Return non-nil when the panel column is on FRAME."
  (seq-some (lambda (window)
              (and (window-parameter window 'window-side)
                   (buffer-local-value 'herdr-panel-refresh-function
                                       (window-buffer window))))
            (window-list frame)))

(defun herdr-ui--show-panels ()
  "Put the panels in their column, spaces above agents."
  (herdr-ui--display (herdr-spaces--prepare) -1 herdr-ui-spaces-height)
  (herdr-ui--display (herdr-agents--prepare) 1
                     (- 1 herdr-ui-spaces-height)))

(defun herdr-ui--clear (&optional frame)
  "Take the herdr side windows off FRAME, leaving other windows alone."
  (dolist (window (window-list frame))
    (when (and (window-parameter window 'window-side)
               (herdr-panel-own-buffer-p (window-buffer window))
               (window-live-p window))
      (delete-window window))))

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

;;; Living With Other Window Packages

(defun herdr-ui-layout-p (&optional frame)
  "Return non-nil while the herdr layout is on FRAME.
The whole layout is protected, not merely the window you are in: a
resize of the terminal moves the panels beside it just as surely."
  (seq-some (lambda (window)
              (herdr-panel-own-buffer-p (window-buffer window)))
            (window-list frame)))

(defun herdr-ui--dimmer-keeps-p (buffer)
  "Return non-nil when dimmer should leave BUFFER at full strength."
  (herdr-panel-own-buffer-p buffer))

(defun herdr-ui--tame ()
  "Ask golden-ratio and dimmer to leave the herdr layout alone.
Idempotent, and narrow: each package is told about herdr's own windows
and nothing else, so both go on behaving as they did elsewhere.  There
is nothing to undo when the layout closes, because both tests answer
no once the herdr buffers are gone."
  (when (boundp 'golden-ratio-inhibit-functions)
    (add-hook 'golden-ratio-inhibit-functions #'herdr-ui-layout-p))
  (when (boundp 'dimmer-buffer-exclusion-predicates)
    (add-hook 'dimmer-buffer-exclusion-predicates
              #'herdr-ui--dimmer-keeps-p)))

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
