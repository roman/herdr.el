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

;; The colours are herdr's own, so that a pane looks the same whichever
;; client is showing it.  They are the Catppuccin flavours herdr ships:
;; Mocha where Emacs reports a dark background, Latte where it reports a
;; light one.  Everything here is a face, so a theme that disagrees can
;; say so without patching the panels.

(defface herdr-panel-blocked
  '((((background dark)) :foreground "#f38ba8")
    (((background light)) :foreground "#d20f39")
    (t :inherit error))
  "Face for the mark of an agent waiting on the user."
  :group 'herdr-panel)

(defface herdr-panel-working
  '((((background dark)) :foreground "#f9e2af")
    (((background light)) :foreground "#df8e1d")
    (t :inherit warning))
  "Face for the mark of an agent that is working."
  :group 'herdr-panel)

(defface herdr-panel-done
  '((((background dark)) :foreground "#94e2d5")
    (((background light)) :foreground "#179299")
    (t :inherit success))
  "Face for the mark of an agent whose finished work nobody has seen."
  :group 'herdr-panel)

(defface herdr-panel-idle
  '((((background dark)) :foreground "#a6e3a1")
    (((background light)) :foreground "#40a043")
    (t :inherit success))
  "Face for the mark of an agent with nothing to report."
  :group 'herdr-panel)

(defface herdr-panel-unknown
  '((((background dark)) :foreground "#6c7086")
    (((background light)) :foreground "#9ca0b0")
    (t :inherit shadow))
  "Face for the mark of a pane herdr has detected no agent in."
  :group 'herdr-panel)

(defface herdr-panel-label
  '((((background dark)) :foreground "#a6adc8")
    (((background light)) :foreground "#6c6f85")
    (t :inherit default))
  "Face for the name on a row that is not the current one."
  :group 'herdr-panel)

(defface herdr-panel-detail
  '((t :inherit herdr-panel-unknown))
  "Face for the trailing detail on a row, such as a terminal title."
  :group 'herdr-panel)

(defface herdr-panel-current
  '((((background dark)) :background "#313244" :extend t)
    (((background light)) :background "#ccd0da" :extend t)
    (t :background "grey25" :extend t))
  "Face filling the row whose pane the selected window shows.
Only a background, and a quiet one: the mark keeps its own colour and
the name is brightened by `herdr-panel-current-label' instead.

Deliberately not inheriting `highlight'.  Themes are free to make that
face shout, and several do; doom-peacock sets it to an orange red,
which against these foregrounds is unreadable.  A row fill has to stay
behind its text."
  :group 'herdr-panel)

(defface herdr-panel-current-label
  '((((background dark)) :foreground "#cdd6f4" :weight bold)
    (((background light)) :foreground "#4c4f69" :weight bold)
    (t :weight bold))
  "Face for the name on the current row."
  :group 'herdr-panel)

(defconst herdr-panel-status-faces
  '(("blocked" . herdr-panel-blocked)
    ("done" . herdr-panel-done)
    ("working" . herdr-panel-working)
    ("idle" . herdr-panel-idle)
    ("unknown" . herdr-panel-unknown))
  "Face for each agent status herdr reports.")

(defcustom herdr-panel-status-symbols
  '(("blocked" . "●") ("done" . "●") ("working" . "●")
    ("idle" . "○") ("unknown" . "·"))
  "Mark shown beside each agent status.
These are herdr's own marks: a filled circle while an agent has
something to say, a hollow one once it has been seen, and a dot where
there is no agent at all."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type string :value-type string))

(defun herdr-panel-status-face (status)
  "Return the face for agent STATUS."
  (or (cdr (assoc status herdr-panel-status-faces)) 'herdr-panel-unknown))

(defun herdr-panel-status-symbol (status)
  "Return the mark shown for agent STATUS."
  (or (cdr (assoc status herdr-panel-status-symbols)) " "))

;; Both `face' and `font-lock-face' are set on everything a panel draws.
;; A panel is a `magit-section-mode' buffer, and font-lock is on in one:
;; the first refontification removes any `face' it did not put there, so a
;; row propertized with `face' alone renders correctly once and then loses
;; its colour with no error to explain it.

(defun herdr-panel--propertize (string face)
  "Return STRING wearing FACE, in a way font-lock will not undo."
  (propertize string 'face face 'font-lock-face face))

(defun herdr-panel--add-face (beg end face)
  "Merge FACE beneath whatever BEG to END already wears."
  (add-face-text-property beg end face t)
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'font-lock-face nil end))
            (worn (ensure-list (get-text-property pos 'font-lock-face))))
        (put-text-property pos next 'font-lock-face
                           (append worn (list face)))
        (setq pos next)))))

(defun herdr-panel-status-string (status)
  "Return STATUS's mark, wearing the face for that status."
  (herdr-panel--propertize (herdr-panel-status-symbol status)
                           (herdr-panel-status-face status)))

(defun herdr-panel-insert-row (status label &optional detail indent current)
  "Insert one panel row, the way herdr draws one.
STATUS picks the mark and its colour, LABEL names the row and DETAIL
trails it.  INDENT goes before the mark, for a row inside a group.

Only the mark is coloured by the status; herdr leaves the name in one
colour and lets the mark carry the state.  A non-nil CURRENT fills the
whole row, which is how herdr shows the pane it is displaying."
  (let ((start (point)))
    (insert (or indent " ")
            (herdr-panel-status-string status)
            " "
            (herdr-panel--propertize label (if current
                                               'herdr-panel-current-label
                                             'herdr-panel-label)))
    (when (and detail (not (string-empty-p detail)))
      (insert "  " (herdr-panel--propertize detail 'herdr-panel-detail)))
    (insert "\n")
    (when current
      ;; Merged beneath, so that the mark and the name keep their own
      ;; colours and only the background comes from here.  Replacing the
      ;; face instead would flatten the row to a single colour.
      (herdr-panel--add-face start (point) 'herdr-panel-current))))

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

(defun herdr-panel-own-buffer-p (buffer)
  "Return non-nil when BUFFER is part of the herdr interface.
That is a panel, or a terminal mirroring a pane."
  (and (buffer-live-p buffer)
       (or (buffer-local-value 'herdr-panel-refresh-function buffer)
           (buffer-local-value 'herdr-term--pane buffer))
       t))

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
