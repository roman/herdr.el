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

(defface herdr-panel-unopened
  '((((background dark)) :foreground "#6c7086")
    (((background light)) :foreground "#9ca0b0")
    (t :inherit shadow))
  "Face for the name of a pane no Emacs buffer is mirroring.
Dimmer than `herdr-panel-label', so that a glance separates what is
open here from what is merely running over there."
  :group 'herdr-panel)

(defface herdr-panel-detail
  '((t :inherit herdr-panel-unknown))
  "Face for text on an entry that no more particular face claims."
  :group 'herdr-panel)

;; A field gets its own colour so that a glance can find one kind of
;; thing among the rest: the branch, the path, the count that is not
;; zero.  All of it gives way on a closed entry, where the point is that
;; the whole thing recedes.

(defface herdr-panel-path
  '((((background dark)) :foreground "#f9e2af")
    (((background light)) :foreground "#df8e1d")
    (t :inherit font-lock-string-face))
  "Face for the directory a workspace sits in.
The yellow a folder is drawn in, chosen because a path has to be told
apart from a dimmed entry at a glance, and any grey quiet enough to
sit behind the name was too near the grey that means \"not open\"."
  :group 'herdr-panel)

(defface herdr-panel-branch
  '((((background dark)) :foreground "#cba6f7")
    (((background light)) :foreground "#8839ef")
    (t :inherit font-lock-keyword-face))
  "Face for a git branch.  This is the colour herdr gives one."
  :group 'herdr-panel)

(defface herdr-panel-ahead
  '((((background dark)) :foreground "#a6e3a1")
    (((background light)) :foreground "#40a043")
    (t :inherit success))
  "Face for how far a checkout is ahead of its upstream."
  :group 'herdr-panel)

(defface herdr-panel-behind
  '((((background dark)) :foreground "#fab387")
    (((background light)) :foreground "#fe640b")
    (t :inherit warning))
  "Face for how far a checkout is behind its upstream."
  :group 'herdr-panel)

(defface herdr-panel-dirty
  '((((background dark)) :foreground "#f38ba8")
    (((background light)) :foreground "#d20f39")
    (t :inherit error))
  "Face for the count of files changed in a checkout.
Red rather than the yellow it had, which the path now wears: two
yellows side by side on one line told nothing apart."
  :group 'herdr-panel)

(defface herdr-panel-agent
  '((((background dark)) :foreground "#94e2d5")
    (((background light)) :foreground "#179299")
    (t :inherit font-lock-type-face))
  "Face for what kind of agent an entry is running."
  :group 'herdr-panel)

(defface herdr-panel-window
  '((((background dark)) :foreground "#89b4fa")
    (((background light)) :foreground "#1e66f5"))
  "Face for the window a pane sits in within its workspace."
  :group 'herdr-panel)

(defface herdr-panel-separator
  '((t :inherit herdr-panel-unknown))
  "Face for the punctuation between fields."
  :group 'herdr-panel)

(defface herdr-panel-read-only
  '((t :inherit herdr-panel-unknown))
  "Face for the mark saying a pane is mirrored for reading only."
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

(defun herdr-panel-text (string face)
  "Return STRING wearing FACE, in a way font-lock will not undo.
Panels use this for each field they draw, so that a field keeps its
own colour when a face is later merged across the whole entry."
  (propertize string 'face face 'font-lock-face face))

(defalias 'herdr-panel--propertize #'herdr-panel-text)

(defun herdr-panel--add-face (beg end face order)
  "Merge FACE into BEG to END, ORDER saying which side wins.
`beneath' leaves what is already there in charge, which is how a row
fill supplies a background without touching any foreground.  `over'
puts FACE in charge, which is how a whole entry is dimmed at once
without having to know what colours its fields chose."
  (let ((append (eq order 'beneath)))
    (add-face-text-property beg end face append)
    (let ((pos beg))
      (while (< pos end)
        (let ((next (next-single-property-change pos 'font-lock-face nil end))
              (worn (ensure-list (get-text-property pos 'font-lock-face))))
          (put-text-property pos next 'font-lock-face
                             (if append
                                 (append worn (list face))
                               (cons face worn)))
          (setq pos next))))))

(defun herdr-panel-status-string (status)
  "Return STATUS's mark, wearing the face for that status."
  (herdr-panel--propertize (herdr-panel-status-symbol status)
                           (herdr-panel-status-face status)))

(defconst herdr-panel-emphasis-faces
  '((current . herdr-panel-current-label)
    (open . herdr-panel-label)
    (closed . herdr-panel-unopened))
  "Face for a row's name at each degree of emphasis.")

(defun herdr-panel-insert-entry (spec)
  "Insert one panel entry described by SPEC.
SPEC is a plist:

  `:status'    the agent status, which picks the mark and its colour
  `:emphasis'  `current' for the pane the selected window shows,
               `open' for one another buffer mirrors, `closed' for one
               with no buffer here
  `:label'     the name, shown beside the mark
  `:aside'     more of the first line, shown after the name
  `:detail'    what follows on further lines, indented under the
               name: a string, a list of strings for several lines, or
               nil for an entry of one line
  `:indent'    what precedes the mark, for an entry inside a group

An entry is one row however many lines it takes.  It is filled as one
when it is `current', and moving between rows steps over it whole.

Only the mark is coloured by the status.  herdr leaves the name in one
colour and lets the mark carry the state, and the mark keeps its
colour even on a closed entry: an agent that wants the user wants them
whether or not they happen to have opened it."
  (let* ((emphasis (plist-get spec :emphasis))
         (detail (plist-get spec :detail))
         (aside (plist-get spec :aside))
         (indent (or (plist-get spec :indent) " "))
         (start (point)))
    (insert indent (herdr-panel-status-string (plist-get spec :status)) " ")
    ;; Beneath, because a label may already have coloured part of itself:
    ;; an agent names its workspace and the window inside it, and those
    ;; are two different things.
    (herdr-panel--add-face
     (point) (progn (insert (plist-get spec :label)) (point))
     (or (cdr (assq emphasis herdr-panel-emphasis-faces))
         'herdr-panel-label)
     'beneath)
    (when (and aside (not (string-empty-p aside)))
      (insert " ")
      (herdr-panel--add-face (point) (progn (insert aside) (point))
                             'herdr-panel-detail 'beneath))
    (insert "\n")
    ;; Aligned under the name rather than under the mark, so a column of
    ;; entries reads as a column of names with notes beneath them.
    (let ((margin (make-string (+ (length indent) 2) ?\s)))
      (dolist (line (ensure-list detail))
        (when (and line (not (string-empty-p line)))
          (insert margin)
          ;; Beneath, so a field that chose a colour keeps it and only
          ;; the text that chose none falls back to this.
          (herdr-panel--add-face (point) (progn (insert line) (point))
                                 'herdr-panel-detail 'beneath)
          (insert "\n"))))
    (when (eq emphasis 'closed)
      ;; Over everything, because the point of a closed entry is that it
      ;; recedes as a whole.  Merged beneath, each field would keep the
      ;; colour that makes it stand out and nothing would recede.
      (herdr-panel--add-face start (point) 'herdr-panel-unopened 'over))
    (when (eq emphasis 'current)
      ;; Beneath, so that the mark and the fields keep their colours and
      ;; only the background comes from here.
      (herdr-panel--add-face start (point) 'herdr-panel-current 'beneath))))

(defun herdr-panel-open-panes ()
  "Return the panes some Emacs buffer is mirroring, in no order."
  (sort (delq nil (mapcar #'herdr-panel--buffer-pane (buffer-list)))
        #'string<))

(defun herdr-panel-pane-open-p (pane)
  "Return non-nil when some Emacs buffer mirrors PANE."
  (and pane (member pane (herdr-panel-open-panes)) t))

(defun herdr-panel-pane-writable-p (pane)
  "Return non-nil when a buffer mirroring PANE can be typed into.
A pane can be mirrored more than once, and one writable mirror is
enough: herdr grants control of a pane to a single client, so that
mirror is the one holding it."
  (and pane
       (seq-some (lambda (buffer)
                   (and (equal (herdr-panel--buffer-pane buffer) pane)
                        (buffer-local-value 'herdr-term--writable buffer)))
                 (buffer-list))
       t))

(defun herdr-panel-emphasis (pane current)
  "Return how to draw a row for PANE, given the CURRENT pane."
  (cond ((and pane (equal pane current)) 'current)
        ((herdr-panel-pane-open-p pane) 'open)
        (t 'closed)))

;;; The Current Pane

(defvar herdr-panel--marks nil
  "What the panels last marked, so a change can be noticed.
This has the form (CURRENT-PANE . OPEN-PANES).")

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
(defvar herdr-term--writable)
(declare-function herdr-term-open "herdr-term" (pane &optional writable))

;;; Panels

(defcustom herdr-panel-mode-line nil
  "Mode line for a panel buffer, or nil to give it none.
A panel is a narrow column of short rows in a window that never
changes what it holds, so a mode line spends a line of height saying
what the buffer name already says.  Set this to the symbol
`mode-line-format' to get the ordinary one back, or to any mode line
construct to choose your own."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(choice (const :tag "None" nil) sexp))

(defvar-local herdr-panel-refresh-function nil
  "Function redrawing this panel, or nil in a buffer that is not one.")

(defvar-local herdr-panel-pane-function nil
  "Function returning the pane the row at point stands for.
It may signal a `user-error' when the row stands for none.")

(defun herdr-panel-init (refresh pane)
  "Prepare the current buffer as a panel.
REFRESH redraws it and PANE answers which pane the row at point
stands for."
  (setq herdr-panel-refresh-function refresh
        herdr-panel-pane-function pane)
  (setq-local mode-line-format
              (if (eq herdr-panel-mode-line 'mode-line-format)
                  (default-value 'mode-line-format)
                herdr-panel-mode-line))
  (add-hook 'kill-buffer-hook #'herdr-panel-unwatch nil t))

;;; Moving Between Rows

;; Only the rows stand for something; the title above them does not, and
;; a cursor that can rest on it can be told to visit nothing.  Every row
;; is a section carrying a value, and the titles are the sections that
;; carry none, so that distinction is the whole test.

(defun herdr-panel-row-p ()
  "Return non-nil when point is on a row that stands for something."
  (let ((section (magit-current-section)))
    (and section (oref section value) t)))

(defun herdr-panel--step (direction)
  "Move point one row in DIRECTION, or return nil having not moved.
Steps between sections rather than between lines, because an entry
spans as many lines as it has to say and is still one row.  Landing on
a section's own start is what keeps a step over a two line entry from
stopping halfway down it."
  (let ((origin (point))
        (from (magit-current-section))
        (target nil))
    (while (and (not target) (zerop (forward-line direction)))
      (let ((section (magit-current-section)))
        (when (and section
                   (not (eq section from))
                   (oref section value))
          (setq target section))))
    (cond
      (target (goto-char (oref target start)) t)
      (t (goto-char origin) nil))))

(defun herdr-panel-next-row (&optional count)
  "Move down COUNT rows, passing over anything that is not one."
  (interactive "p")
  (dotimes (_ (or count 1))
    (herdr-panel--step 1)))

(defun herdr-panel-previous-row (&optional count)
  "Move up COUNT rows, passing over anything that is not one."
  (interactive "p")
  (dotimes (_ (or count 1))
    (herdr-panel--step -1)))

(defun herdr-panel-first-row ()
  "Move to the first row."
  (interactive)
  (goto-char (point-min))
  (unless (herdr-panel-row-p)
    (herdr-panel--step 1)))

(defun herdr-panel-last-row ()
  "Move to the last row."
  (interactive)
  (goto-char (point-max))
  (unless (herdr-panel-row-p)
    (herdr-panel--step -1)))

(defun herdr-panel-settle-point ()
  "Put point on a row, when a redraw has left it somewhere else.
Each window showing the panel is settled too.  A displayed buffer
keeps a point per window, and that is the one a reader arrives on, so
settling only the buffer's own leaves the cursor on the title of every
window that was not selected at the time."
  (unless (herdr-panel-row-p)
    (or (herdr-panel--step 1) (herdr-panel--step -1)))
  (dolist (window (get-buffer-window-list nil nil t))
    (unless (save-excursion
              (goto-char (window-point window))
              (herdr-panel-row-p))
      (set-window-point window (point)))))

;;; Acting on a Row

(defun herdr-panel-visit ()
  "Show the terminal for the row at point."
  (interactive)
  (unless herdr-panel-pane-function
    (user-error "Not in a herdr panel"))
  (herdr-panel-open-pane (funcall herdr-panel-pane-function)))

(defun herdr-panel-refresh ()
  "Redraw this panel now."
  (interactive)
  (unless herdr-panel-refresh-function
    (user-error "Not in a herdr panel"))
  (funcall herdr-panel-refresh-function))

;;; Keys

(defvar-keymap herdr-panel-mode-map
  :doc "Keymap shared by the herdr panels."
  :parent magit-section-mode-map
  "RET" #'herdr-panel-visit
  "n" #'herdr-panel-next-row
  "p" #'herdr-panel-previous-row
  "<down>" #'herdr-panel-next-row
  "<up>" #'herdr-panel-previous-row
  "g" #'herdr-panel-refresh
  "q" #'quit-window)

(defconst herdr-panel-evil-blocked-keys
  '("i" "I" "a" "A" "o" "O" "c" "C" "s" "S" "R" "x" "d" "p" "P" "u")
  "Normal state keys that a panel refuses.
A panel shows a list that herdr owns.  Nothing here can be typed into
or edited, and a key that silently enters insert state leaves the next
keystroke doing nothing anyone asked for.")

(defun herdr-panel-install-evil-keys (map)
  "Give MAP the panel's normal state bindings.
evil's own normal state map shadows a major mode map, so a panel that
binds only the latter appears to have no keys at all under evil."
  (when (fboundp 'evil-define-key*)
    (apply #'evil-define-key* 'normal map
           (append
            (list (kbd "RET") #'herdr-panel-visit
                  "j" #'herdr-panel-next-row
                  "k" #'herdr-panel-previous-row
                  "n" #'herdr-panel-next-row
                  "p" #'herdr-panel-previous-row
                  (kbd "<down>") #'herdr-panel-next-row
                  (kbd "<up>") #'herdr-panel-previous-row
                  "gg" #'herdr-panel-first-row
                  "G" #'herdr-panel-last-row
                  "gr" #'herdr-panel-refresh
                  (kbd "TAB") #'magit-section-toggle
                  "q" #'quit-window)
            (mapcan (lambda (key) (list key #'ignore))
                    herdr-panel-evil-blocked-keys)))))

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

(defun herdr-panel-marks ()
  "Return what the panels mark, as a value that can be compared.
The pane in front of you, and every pane open here with whether it can
be typed into.  None of this is in the session tree: all of it is a
fact about Emacs, so no event from herdr will report any of it."
  (cons (herdr-panel-current-pane)
        (mapcar (lambda (pane)
                  (cons pane (herdr-panel-pane-writable-p pane)))
                (herdr-panel-open-panes))))

(defun herdr-panel--note-marks (&rest _)
  "Redraw the panels when what they mark has changed."
  (let ((marks (herdr-panel-marks)))
    (unless (equal marks herdr-panel--marks)
      (setq herdr-panel--marks marks)
      (herdr-panel-refresh-all))))

(defun herdr-panel-watch ()
  "Keep the panels current with the session and with the selection.
Idempotent, so every panel may call it as it opens."
  (add-hook 'herdr-session-change-hook #'herdr-panel-refresh-all)
  (add-hook 'window-selection-change-functions #'herdr-panel--note-marks)
  ;; Also on a window changing buffer, which is how a terminal opened or
  ;; killed elsewhere becomes visible to the panels.
  (add-hook 'window-buffer-change-functions #'herdr-panel--note-marks)
  ;; Taking control of a pane changes no window, so nothing above would
  ;; notice it.  The poll does.
  (add-hook 'herdr-session-fingerprint-functions #'herdr-panel-marks)
  (unless (herdr-session-live-p)
    (herdr-session-start)))

(defun herdr-panel-unwatch ()
  "Stop keeping the panels current, once none of them is left."
  (unless (seq-some (lambda (buffer)
                      (buffer-local-value 'herdr-panel-refresh-function
                                          buffer))
                    (buffer-list))
    (remove-hook 'herdr-session-change-hook #'herdr-panel-refresh-all)
    (remove-hook 'window-selection-change-functions #'herdr-panel--note-marks)
    (remove-hook 'window-buffer-change-functions #'herdr-panel--note-marks)
    (remove-hook 'herdr-session-fingerprint-functions #'herdr-panel-marks)))

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

(defun herdr-panel-main-window (&optional frame)
  "Return the window on FRAME that the panels send terminals to.
A window already mirroring a pane wins, so a layout keeps showing its
terminals in the same place.  Failing that, any window that is not one
of the side windows the panels themselves live in."
  (let ((windows (seq-remove (lambda (window)
                               (window-parameter window 'window-side))
                             (window-list frame))))
    (or (seq-find (lambda (window)
                    (herdr-panel--buffer-pane (window-buffer window)))
                  windows)
        (car windows))))

(defun herdr-panel--display-in-main (buffer _alist)
  "Show BUFFER in the main window, for `display-buffer'.
Return that window, or nil when the frame has none to offer, which
leaves `display-buffer' to go on looking."
  (when-let* ((window (herdr-panel-main-window)))
    (set-window-buffer window buffer)
    window))

(defun herdr-panel-open-pane (pane)
  "Show the terminal for PANE and move to it.
The terminal replaces whatever the main window held, rather than
splitting or taking over the panel: a panel is furniture, and a layout
that rearranged itself every time a row was visited would be worse
than one window showing one pane.

Selecting the terminal is what herdr does when a row is activated, and
here it also moves the panels' own highlight onto the row just
visited, because that highlight follows the selected window."
  (require 'herdr-term)
  (let ((display-buffer-overriding-action
         '((herdr-panel--display-in-main))))
    (herdr-term-open pane))
  (when-let* ((buffer (seq-find (lambda (buffer)
                                  (equal (herdr-panel--buffer-pane buffer)
                                         pane))
                                (buffer-list)))
              (window (get-buffer-window buffer)))
    (select-window window)))

;;; _
(provide 'herdr-panel)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-panel.el ends here
