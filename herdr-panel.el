;;; herdr-panel.el --- Shared machinery for the herdr panels  -*- lexical-binding:t -*-

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

;; What every herdr panel needs and none of them should each own: the
;; status faces, the rule for which pane counts as current, and the wiring
;; that redraws a panel when either the session or the selection moves.

;; herdr has one focus.  Emacs has two, and they disagree: the pane herdr
;; focused, and the pane the window you are looking at shows.  The panels
;; follow the second, so that they describe what is in front of you and
;; move with you between windows.  `herdr-panel-current-pane' is that rule,
;; in one place, because a panel that answered it differently from its
;; neighbour would highlight a different row.

;;; Code:

(require 'magit-section)
(require 'seq)

(require 'herdr-session)

;;; Faces

(defgroup herdr-panel nil
  "Panels showing the herdr session."
  :group 'herdr-session
  :prefix "herdr-panel-")

(defface herdr-panel-blocked '((t :inherit error :weight bold))
  "Face for an agent waiting on the user."
  :group 'herdr-panel)

(defface herdr-panel-done '((t :inherit success :weight bold))
  "Face for an agent that finished work nobody has looked at yet."
  :group 'herdr-panel)

(defface herdr-panel-working '((t :inherit warning))
  "Face for an agent that is working."
  :group 'herdr-panel)

(defface herdr-panel-idle '((t :inherit shadow))
  "Face for an agent with nothing to report."
  :group 'herdr-panel)

(defface herdr-panel-unknown '((t :inherit shadow))
  "Face for a pane herdr has detected no agent in."
  :group 'herdr-panel)

(defface herdr-panel-current '((t :inherit highlight :extend t))
  "Face marking the row whose pane the selected window shows."
  :group 'herdr-panel)

(defconst herdr-panel-status-faces
  '(("blocked" . herdr-panel-blocked)
    ("done" . herdr-panel-done)
    ("working" . herdr-panel-working)
    ("idle" . herdr-panel-idle)
    ("unknown" . herdr-panel-unknown))
  "Face for each agent status herdr reports.")

(defcustom herdr-panel-status-symbols
  '(("blocked" . "!") ("done" . "*") ("working" . ">")
    ("idle" . "-") ("unknown" . " "))
  "Mark shown beside each agent status.
These are plain ASCII so that a panel stays readable in a terminal
frame with no glyphs for anything better."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type string :value-type string))

(defun herdr-panel-status-face (status)
  "Return the face for agent STATUS."
  (or (cdr (assoc status herdr-panel-status-faces)) 'herdr-panel-unknown))

(defun herdr-panel-status-symbol (status)
  "Return the mark shown for agent STATUS."
  (or (cdr (assoc status herdr-panel-status-symbols)) " "))

(defun herdr-panel-status-string (status)
  "Return STATUS's mark, propertized with its face."
  (propertize (herdr-panel-status-symbol status)
              'face (herdr-panel-status-face status)))

;;; The Current Pane

(defvar herdr-panel--current-pane nil
  "Pane the panels last highlighted, so a change can be noticed.")

(defun herdr-panel-current-pane ()
  "Return the pane mirrored by the window you are looking at, or nil.
The selected window wins.  Otherwise the most recently selected herdr
terminal does, which is what keeps the highlight still while you work
inside a panel rather than clearing it."
  (or (herdr-panel--buffer-pane (window-buffer (selected-window)))
      (seq-some #'herdr-panel--buffer-pane (buffer-list))))

(defun herdr-panel--buffer-pane (buffer)
  "Return the herdr pane BUFFER mirrors, or nil when it mirrors none."
  (buffer-local-value 'herdr-term--pane buffer))

;; Declared rather than required: a panel must stay usable without the
;; terminal, whose ghostel dependency loads a native module.
(defvar herdr-term--pane)
(declare-function herdr-term-open "herdr-term" (pane &optional writable))

;;; Panels

(defvar-local herdr-panel-refresh-function nil
  "Function redrawing this panel, or nil in a buffer that is not one.")

(defun herdr-panel-refresh-all ()
  "Redraw every live panel."
  (dolist (buffer (buffer-list))
    (when-let* ((refresh (buffer-local-value 'herdr-panel-refresh-function
                                             buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (funcall refresh))))))

(defun herdr-panel--note-selection (&rest _)
  "Redraw the panels when the selected window changed which pane is current."
  (let ((pane (herdr-panel-current-pane)))
    (unless (equal pane herdr-panel--current-pane)
      (setq herdr-panel--current-pane pane)
      (herdr-panel-refresh-all))))

(defun herdr-panel-watch ()
  "Keep the panels current with the session and with the selection.
Idempotent, so every panel may call it as it opens."
  (add-hook 'herdr-session-change-hook #'herdr-panel-refresh-all)
  (add-hook 'window-selection-change-functions
            #'herdr-panel--note-selection)
  (unless (herdr-session-live-p)
    (herdr-session-start)))

(defun herdr-panel-unwatch ()
  "Stop keeping the panels current, once none of them is left."
  (unless (seq-some (lambda (buffer)
                      (buffer-local-value 'herdr-panel-refresh-function
                                          buffer))
                    (buffer-list))
    (remove-hook 'herdr-session-change-hook #'herdr-panel-refresh-all)
    (remove-hook 'window-selection-change-functions
                 #'herdr-panel--note-selection)))

;;; Rendering

(defmacro herdr-panel-with-redraw (&rest body)
  "Redraw the current panel by running BODY, keeping the reader's place.
Point and the window's start are restored, so a redraw provoked by an
event somewhere else does not move what the reader is looking at."
  (declare (indent 0) (debug t))
  (let ((line (make-symbol "line"))
        (start (make-symbol "start")))
    `(let ((,line (line-number-at-pos))
           (,start (and (get-buffer-window) (window-start)))
           (inhibit-read-only t))
       (erase-buffer)
       ,@body
       (goto-char (point-min))
       (forward-line (1- ,line))
       (when-let* ((window (get-buffer-window)))
         (set-window-start window (min ,start (point-max)) t)))))

(defun herdr-panel-open-pane (pane)
  "Show the terminal for PANE, creating its buffer when there is none."
  (require 'herdr-term)
  (herdr-term-open pane))

;;; _
(provide 'herdr-panel)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-panel.el ends here
