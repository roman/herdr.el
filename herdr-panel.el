;;; herdr-panel.el --- Shared machinery for the herdr panels  -*- lexical-binding:t -*-

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

;; The four status marks depart from Mocha, and only on a dark background.
;; Mocha's are pastels: light and barely saturated, which is what they are
;; for behind a wall of code.  A mark is one glyph wide, three of the
;; statuses draw the same glyph, and colour is the whole of what tells them
;; apart — and against a black background the pastels lose the little
;; saturation they had and read as three shades of pale.  So each mark
;; keeps Mocha's hue and takes as much of it as the terminal will give.
;; Every field that is text rather than a mark stays pastel, which leaves
;; the marks the loudest thing in the column: they are what a reader scans.

(defface herdr-panel-blocked
  '((((background dark)) :foreground "#ff3b47")
    (((background light)) :foreground "#d20f39")
    (t :inherit error))
  "Face for the mark of an agent waiting on the user."
  :group 'herdr-panel)

(defface herdr-panel-working
  '((((background dark)) :foreground "#ffcc00")
    (((background light)) :foreground "#df8e1d")
    (t :inherit warning))
  "Face for the mark of an agent that is working."
  :group 'herdr-panel)

(defface herdr-panel-done
  '((((background dark)) :foreground "#00e5c0")
    (((background light)) :foreground "#179299")
    (t :inherit success))
  "Face for the mark of an agent whose finished work nobody has seen."
  :group 'herdr-panel)

(defface herdr-panel-idle
  '((((background dark)) :foreground "#2fe86b")
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

(defface herdr-panel-border
  '((((background dark)) :overline "#45475a" :extend t)
    (((background light)) :overline "#bcc0cc" :extend t)
    (t :overline t :extend t))
  "Face ruling a line off from whatever sits above it.
An overline on the panel's own first line, rather than a window
divider or a header line: it costs no row of height, and it draws
where this panel begins instead of between every pair of windows on
the frame."
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

(defface herdr-panel-attention-blocked
  '((((background dark)) :background "#5b3a48" :extend t)
    (((background light)) :background "#eeb9c8" :extend t)
    (t :inherit herdr-panel-current))
  "Face flashing the row of an agent that has begun waiting on the user.
The mark says that the agent is waiting, but a mark is one character
wide in a column of them and is easy to walk past.  This fills the
whole row while the row pulses, so that an agent that starts waiting
while you are reading something else catches the corner of your eye.
The fill goes when the pulse ends; see `herdr-panel-attention-pulses'.

Red where `herdr-panel-current' is grey, and further from the panel's
background than that face is, so that a row wanting the user is the
louder of the two wherever both are on screen.

Only a background, like `herdr-panel-current', and for the same
reason: every field on the row keeps the colour it chose.  It fills
over the current row rather than under it, because which row wants you
outranks which row you happen to be looking at, and the name on the
current row stays bold either way.

Where Emacs reports neither a dark nor a light background there is no
colour that can be relied on, so the row is filled as the current one
is: still a fill, without the colour."
  :group 'herdr-panel)

(defface herdr-panel-attention-done
  '((((background dark)) :background "#2f4a42" :extend t)
    (((background light)) :background "#9fd4ae" :extend t)
    (t :inherit herdr-panel-current))
  "Face flashing the row of an agent that has just finished unwatched.
Green against the red of `herdr-panel-attention-blocked', and matched
to it in weight rather than pitched under it: an agent that has
stopped is as easy to leave sitting there as one that is asking, and
the two are told apart by which colour they are, not by how loud.  The
teal of `herdr-panel-done' sits on this, so the mark stays legible.

See `herdr-panel-attention-blocked' for why a whole row is filled, how
long for, and how the fill merges."
  :group 'herdr-panel)

(defface herdr-panel-point
  '((((background dark)) :background "#45475a" :extend t)
    (((background light)) :background "#bcc0cc" :extend t)
    (t :inherit region))
  "Face marking the row point rests on, in place of the block cursor.
A panel is a list to walk, and a square sitting on one character of a
row says less about where you are than the row itself does.  A step
brighter than `herdr-panel-current', so that the row you are on and
the pane you are looking at stay apart when they are not the same row.

This one is an overlay rather than a merged face, so on the row it
covers it hides whatever fill was underneath, an attention fill
included.  That is why it is shown only while the panel window is
selected: leave the panel and every row is its own colour again."
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

(defcustom herdr-panel-attention-faces
  '(("blocked" . herdr-panel-attention-blocked)
    ("done" . herdr-panel-attention-done))
  "Face flashing the whole row of each status that wants the user.
An entry is (STATUS . FACE).  These are the two states that stay until
somebody acts on them: an agent waiting on an answer, and work that
finished with nobody watching.  Every other status colours its mark
and nothing else, because a panel that lit every interesting row would
say no more than one that lit none.

The fill arrives with the status and goes a moment later, which is what
makes it a flash rather than a colour the row keeps; see
`herdr-panel-attention-pulses'.

Drop an entry to have that status go back to its mark alone."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type string :value-type face))

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

(defun herdr-panel-attention-face (status)
  "Return the face filling a row in STATUS, or nil when none fills it.
Which statuses are filled, and with what, is
`herdr-panel-attention-faces'."
  (cdr (assoc status herdr-panel-attention-faces)))

(defun herdr-panel-mark-attention (beg end spec)
  "Fill BEG to END while the row SPEC describes is pulsing for the user.
SPEC is a row as `herdr-panel-insert-entry' takes it, of which
`:status' chooses the colour of the fill and `:id' says which row is
pulsing.

Over whatever is already there, so that the fill outranks the one on
the current row.  A fill carries no foreground, so every field
underneath it keeps its own colour, a dimmed row included."
  (when-let* (((herdr-panel-attention-pulsing-p (plist-get spec :id)))
              (face (herdr-panel-attention-face (plist-get spec :status))))
    (herdr-panel--add-face beg end face 'over)))

(defun herdr-panel-status-string (status)
  "Return STATUS's mark, wearing the face for that status."
  (herdr-panel--propertize (herdr-panel-status-symbol status)
                           (herdr-panel-status-face status)))

(defconst herdr-panel-emphasis-faces
  '((current . herdr-panel-current-label)
    (open . herdr-panel-label)
    (closed . herdr-panel-unopened))
  "Face for a row's name at each degree of emphasis.")

(defun herdr-panel-insert-title (title &optional border)
  "Insert TITLE as this panel's heading.
BORDER, when given, is a face ruling the heading off from whatever is
above it; `herdr-panel-border' is the face meant for that."
  (let ((start (point)))
    (magit-insert-heading title)
    (when border
      (herdr-panel--add-face start (point) border 'beneath))))

(defun herdr-panel-insert-entry (spec)
  "Insert one panel entry described by SPEC.
SPEC is a plist:

  `:status'    the agent status, which picks the mark and its colour
  `:emphasis'  `current' for the pane the selected window shows,
               `open' for one another buffer mirrors, `closed' for one
               with no buffer here
  `:id'        what the row stands for, as herdr names it: a pane, a
               workspace or a space.  This is the identity a pulse
               follows, so a row given none never flashes
  `:label'     the name, shown beside the mark
  `:aside'     more of the first line, shown after the name
  `:detail'    what follows on further lines, indented under the
               name: a string, a list of strings for several lines, or
               nil for an entry of one line
  `:indent'    what precedes the mark, for an entry inside a group

An entry is one row however many lines it takes.  It is filled as one
when it is `current', and moving between rows steps over it whole.

The status colours the mark, and it keeps that colour on a closed
entry: an agent that wants the user wants them whether or not they
happen to have opened it.  A status named in
`herdr-panel-attention-faces' fills the whole row as well, for the few
moments it pulses."
  (let* ((emphasis (plist-get spec :emphasis))
         (status (plist-get spec :status))
         (detail (plist-get spec :detail))
         (aside (plist-get spec :aside))
         (indent (or (plist-get spec :indent) " "))
         (start (point)))
    (insert indent (herdr-panel-status-string status) " ")
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
      (herdr-panel--add-face start (point) 'herdr-panel-current 'beneath))
    ;; Last, so that this fill is the one in front of the current row's.
    (herdr-panel-mark-attention start (point) spec)))

(defun herdr-panel-entry-line (spec)
  "Return SPEC drawn as one line, for offering a row in the minibuffer.
Drawn by `herdr-panel-insert-entry' and then folded onto one line,
rather than drawn a second way, so that a row offered by name is the
row the panel draws and stays that way.  What a panel puts on lines of
its own comes up onto the end of the name here, because a candidate is
one line and because those lines hold much of what a reader types to
pick one: the directory, the title an agent gave itself.  A row has
nothing to indent against in a prompt, so `:indent' is dropped."
  (with-temp-buffer
    (herdr-panel-insert-entry (append '(:indent "") spec))
    (goto-char (point-min))
    ;; Carrying the newline's own properties, which is what keeps the
    ;; fill under a current row unbroken across the join.
    (while (re-search-forward "\n *" nil t)
      (replace-match (apply #'propertize "  "
                            (text-properties-at (match-beginning 0)))
                     t t))
    (string-trim-right (buffer-string))))

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
       (boundp 'herdr-term--writable)
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

;;; Pulsing A Row That Has Just Begun Wanting The User

;; A fill that stays says two things at once: that a row wants the user,
;; and that it has only just begun to.  The mark says the first for as long
;; as the status lasts, and a background that never goes stops being read
;; after the first minute of a session.  So the fill is spent on the
;; second.  A row that changes into a status naming one flashes
;; `herdr-panel-attention-pulses' times and then settles back to its mark.

;; What pulses is keyed by what a row stands for, which every panel passes
;; as the `:id' of its entry: a pane in the agents and reviews panels, a
;; workspace or a space in the spaces panel.  herdr reports a status for
;; each of those, so a change that reaches one row leaves the others alone
;; instead of flashing the whole column.

;; Each phase redraws every panel, because a fill is merged into the text a
;; panel draws rather than laid over it.  That is a redraw or six spread
;; over a second or two, and only after something changed; a panel already
;; redraws itself whenever the session moves.

(defcustom herdr-panel-attention-pulses 3
  "How many times a row flashes when it begins wanting the user.
The flash reports that the status is new.  What the row wants is said by
its mark, which stays for as long as the status does, so zero here is a
session that answers the question with the marks alone."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'natnum)

(defcustom herdr-panel-attention-pulse-interval 0.4
  "Seconds a row stays lit, and then dark, in each of its pulses.
A pulse is one of each, so a row flashing three times has finished
after six of these."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

(defvar herdr-panel--pulses (make-hash-table :test #'equal)
  "Phases each pulsing row has left, keyed by what the row stands for.
A row absent from this is not pulsing.  The count runs down from an odd
number and the phases alternate from a lit one, so a row is lit while
its count is odd.")

(defvar herdr-panel--pulse-statuses (make-hash-table :test #'equal)
  "The status each row was last seen in, keyed by what it stands for.
A row absent from this has never been seen, and its first status is no
change: without that, every agent already waiting would flash the
moment a panel opened.")

(defvar herdr-panel--pulse-timer nil
  "Timer stepping the pulses, or nil while no row is pulsing.")

(defun herdr-panel-attention-pulsing-p (id)
  "Return non-nil when the row standing for ID is lit by a pulse.
Nil for a row that is dark between two flashes as well as for one that
has finished flashing: a panel draws the fill only where this says so."
  (when-let* ((phases (and id (gethash id herdr-panel--pulses))))
    (= (mod phases 2) 1)))

(defun herdr-panel--pulse-begin (id)
  "Start the row standing for ID flashing, or leave it to its mark.
`herdr-panel-attention-pulses' set to zero asks for no flash at all,
and a row given no phases never lights."
  (let ((phases (1- (* 2 herdr-panel-attention-pulses))))
    (if (> phases 0)
        (puthash id phases herdr-panel--pulses)
      (remhash id herdr-panel--pulses))))

(defun herdr-panel--pulse-statuses ()
  "Return the status of every row a panel can draw, keyed by the row.
Panes, workspaces and spaces, because each of those is a row in one
panel or another and herdr reports a status for each.  A pane running
no agent is left out: there is nothing in it to ask for anything."
  (let ((statuses (make-hash-table :test #'equal)))
    (dolist (agent (herdr-session-agents))
      (puthash (gethash "pane_id" agent)
               (herdr-session-status agent) statuses))
    (dolist (workspace (herdr-session-workspaces))
      (puthash (gethash "workspace_id" workspace)
               (herdr-session-status workspace) statuses))
    (dolist (space (herdr-session-spaces))
      (puthash (plist-get space :key)
               (plist-get space :agent-status) statuses))
    statuses))

(defun herdr-panel--note-attention ()
  "Flash every row that has just begun wanting the user.
Called with a fresh tree in hand and before the panels redraw, so that
a pulse beginning here is lit by the redraw that follows rather than
one tree later."
  (let ((statuses (herdr-panel--pulse-statuses)))
    (maphash
     (lambda (id status)
       (let ((previous (gethash id herdr-panel--pulse-statuses 'unseen)))
         (cond
           ((not (herdr-panel-attention-face status))
            (remhash id herdr-panel--pulses))
           ((eq previous 'unseen))
           ((equal previous status))
           (t (herdr-panel--pulse-begin id)))))
     statuses)
    ;; A row herdr no longer reports keeps no pulse, or the table grows for
    ;; as long as Emacs runs and lights whatever reuses its name.
    (maphash (lambda (id _)
               (unless (gethash id statuses)
                 (remhash id herdr-panel--pulses)))
             (copy-hash-table herdr-panel--pulses))
    (setq herdr-panel--pulse-statuses statuses)
    (herdr-panel--pulse-schedule)))

(defun herdr-panel--pulse-schedule ()
  "Step the pulses while a row is flashing, and stop stepping after.
One timer however many rows flash together, started when the first of
them does and cancelled when the last one finishes: a timer left
running would redraw every panel for as long as Emacs lives."
  (if (zerop (hash-table-count herdr-panel--pulses))
      (when (timerp herdr-panel--pulse-timer)
        (cancel-timer herdr-panel--pulse-timer)
        (setq herdr-panel--pulse-timer nil))
    (unless (timerp herdr-panel--pulse-timer)
      (setq herdr-panel--pulse-timer
            (run-at-time herdr-panel-attention-pulse-interval
                         herdr-panel-attention-pulse-interval
                         #'herdr-panel--pulse-step)))))

(defun herdr-panel--pulse-step ()
  "Take every pulsing row on to its next phase and redraw the panels."
  (maphash (lambda (id phases)
             (if (> phases 1)
                 (puthash id (1- phases) herdr-panel--pulses)
               (remhash id herdr-panel--pulses)))
           (copy-hash-table herdr-panel--pulses))
  (herdr-panel--pulse-schedule)
  (herdr-panel-refresh-all))

(defun herdr-panel--pulse-forget ()
  "Stop every pulse and forget every status, as the last panel closes.
Forgotten rather than kept, so that the first tree the next panel reads
is no change and nothing flashes for a status it opened onto."
  (clrhash herdr-panel--pulses)
  (clrhash herdr-panel--pulse-statuses)
  (herdr-panel--pulse-schedule))

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
  "Return the herdr pane BUFFER mirrors, or nil when it mirrors none.
Nil, rather than an error, when the terminal has never been loaded:
the variable below is declared here and given its value there, and
`buffer-local-value' signals on one that is declared and unbound."
  (and (boundp 'herdr-term--pane)
       (buffer-local-value 'herdr-term--pane buffer)))

;; Declared rather than required: a panel must stay usable without the
;; terminal, whose ghostel dependency loads a native module.
(defvar herdr-term--pane)
(defvar herdr-term--writable)
(declare-function herdr-term-open "herdr-term" (pane &optional writable))
(declare-function herdr-term-take-control "herdr-term" ())

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

(defcustom herdr-panel-point-style 'row
  "How a panel marks the row point rests on.
`row' takes the block cursor away and highlights the whole row with
`herdr-panel-point' instead, for as long as the panel window is
selected.  An entry is one row however many lines it takes, and the
highlight covers all of them, which a cursor cannot say.

`cursor' marks nothing and leaves the ordinary cursor where it was."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(choice (const :tag "Highlight the whole row" row)
                 (const :tag "Leave the block cursor" cursor)))

(defvar-local herdr-panel-refresh-function nil
  "Function redrawing this panel, or nil in a buffer that is not one.")

(defcustom herdr-panel-visit-access 'control
  "How a panel opens the terminal for a row it visits.
`control' gives a terminal that takes what is typed at it, which is
what opening one is usually for.  `observe' gives one that only shows
the pane and leaves control wherever it already was, which is worth
having when a panel is being read rather than acted on: herdr grants
control to a single client, so a terminal opened here takes it from
the herdr terminal.

A prefix argument to `herdr-panel-visit' asks for the other one."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(choice (const :tag "Take control" control)
                 (const :tag "Observe only" observe)))

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
  (when (eq herdr-panel-point-style 'row)
    ;; Two cursors to take away, and neither covers the other.  This one
    ;; is the hollow box Emacs draws in a window nobody is in, which
    ;; `cursor-type' does not reach, and which lands on the space a row
    ;; opens with — a square at the very left of every panel at once.
    (setq-local cursor-in-non-selected-windows nil)
    (herdr-panel-hide-cursor)
    (add-hook 'post-command-hook #'herdr-panel-track-point nil t))
  (add-hook 'kill-buffer-hook #'herdr-panel-unwatch nil t))

;;; The Row Point Rests On

;; Three things want to colour a row: the pane in front of you, a status
;; that wants you, and where point is.  The first two are merged into the
;; text and can share it.  This one cannot — it has to follow point
;; without a redraw, so it is an overlay, and an overlay covers what is
;; under it.  Showing it only in the selected window is what keeps it from
;; standing on an attention fill for as long as Emacs is running: step out
;; of the panel and the row goes back to saying what it is.

(defvar-local herdr-panel--point-overlay nil
  "Overlay marking the row point rests on, or nil when there is none.")

(defun herdr-panel--point-overlay ()
  "Return this panel's point overlay, making one if it has none."
  (if (overlayp herdr-panel--point-overlay)
      herdr-panel--point-overlay
    (setq herdr-panel--point-overlay
          (let ((overlay (make-overlay (point-min) (point-min) nil nil t)))
            (overlay-put overlay 'face 'herdr-panel-point)
            ;; Above the fills merged into the text, and named rather
            ;; than left at nil so that it is one number to change when
            ;; something else wants to draw over a row.
            (overlay-put overlay 'priority 1)
            overlay))))

(defun herdr-panel-hide-cursor ()
  "Take the cursor off this panel, for as long as it stays off.
Said again after every command rather than once, because evil sets
`cursor-type' from the current state whenever it refreshes, and a
value written once at mode setup is gone by the first keystroke."
  (unless (null cursor-type)
    (setq-local cursor-type nil)))

(defun herdr-panel-track-point (&rest _)
  "Mark the row point rests on in this panel, or unmark it.
Marked only while this buffer is the selected window's, because the
highlight stands in for a cursor and an unselected window shows none.
The cursor is taken off here too: both answer the one question of how
a panel says where you are."
  (when (and herdr-panel-refresh-function
             (eq herdr-panel-point-style 'row))
    (herdr-panel-hide-cursor)
    (if-let* (((eq (current-buffer) (window-buffer (selected-window))))
              ((herdr-panel-row-p))
              (section (magit-current-section)))
        (move-overlay (herdr-panel--point-overlay)
                      (oref section start) (oref section end))
      (when (overlayp herdr-panel--point-overlay)
        (delete-overlay herdr-panel--point-overlay)))))

(defun herdr-panel-track-point-everywhere (&rest _)
  "Mark the row point rests on in every panel there is.
For the moment the selection moves: the panel being left runs no
command of its own to notice, and would keep its highlight."
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'herdr-panel-refresh-function buffer)
      (with-current-buffer buffer
        (herdr-panel-track-point)))))

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
      (set-window-point window (point))))
  ;; `erase-buffer' leaves the point overlay collapsed at the top of the
  ;; buffer, and a redraw on a timer is followed by no command that would
  ;; put it back.
  (herdr-panel-track-point))

;;; Acting on a Row

(defun herdr-panel-visit (&optional other)
  "Show the terminal for the row at point.
With a prefix argument OTHER, open it the other way round from
`herdr-panel-visit-access'."
  (interactive "P")
  (unless herdr-panel-pane-function
    (user-error "Not in a herdr panel"))
  (herdr-panel-open-pane (funcall herdr-panel-pane-function)
                         (herdr-panel-access other)))

(defun herdr-panel-visit-click (event)
  "Show the terminal for the row EVENT was clicked on.
Point moves to the click before anything else, because every panel
answers what a row stands for from the section at point: a command
that only opened would open whatever the cursor was resting on.  A
prefix argument means here what it means to `herdr-panel-visit'."
  (interactive "e")
  (mouse-set-point event)
  (herdr-panel-visit current-prefix-arg))

(defun herdr-panel-access (invert)
  "Return how to open a terminal, INVERT swapping the usual answer.
The usual answer is `herdr-panel-visit-access'.  Every way of reaching
a row asks here, so naming one in the minibuffer lands exactly where
pressing RET on it would have."
  (if invert
      (if (eq herdr-panel-visit-access 'control) 'observe 'control)
    herdr-panel-visit-access))

(defun herdr-panel-refresh ()
  "Redraw this panel now."
  (interactive)
  (unless herdr-panel-refresh-function
    (user-error "Not in a herdr panel"))
  (funcall herdr-panel-refresh-function))

;;; Reading a Row by Name

;; A panel is a list you walk to.  The same list can be typed at, which
;; is quicker once you know which row you want, and which is what a
;; completion framework is on hand for.  Each panel builds its own rows,
;; because only it knows what they are; everything about offering them
;; lives here, so that the prompts behave alike whichever panel raised
;; one.

;; A row opens with its status mark, which is what a reader scans a
;; column for and so has to survive into the prompt.  It also means the
;; text a reader types is never a prefix of the candidate, and `basic',
;; the style Emacs completes with out of the box, matches only prefixes:
;; without this, typing a workspace's name would complete nothing at
;; all.  `completion-category-defaults' is where a library says how its
;; own category should be matched, and a user's
;; `completion-category-overrides' still wins over it, so a setup with
;; orderless or fuzzy matching goes on using that.
(add-to-list 'completion-category-defaults
             '(herdr-pane (styles basic substring)))

(defun herdr-panel-ensure-session ()
  "Make sure there is a session tree to read rows out of.
A command that names a row rather than walking to one may be the first
herdr command of the session.  It takes a snapshot rather than start
the tracking a panel needs: nothing here is going to be redrawn, and a
subscription and a poll timer begun with no panel on the frame would
have nothing left to stop them again."
  (unless (herdr-session-live-p)
    (herdr-session-refresh)))

(defun herdr-panel-read-pane (prompt rows)
  "Read one of ROWS under PROMPT and return the pane it stands for.
ROWS is a list of (LINE . PANE), each LINE built by
`herdr-panel-entry-line'.  They are offered in the order given rather
than sorted, because a panel has already put whatever wants attention
at the top of it."
  (let ((rows (herdr-panel--distinct rows)))
    (or (cdr (assoc (completing-read prompt (herdr-panel--table rows) nil t)
                    rows))
        ;; `completing-read' lets the empty string out however much a
        ;; match is required of everything else, so a prompt answered
        ;; with nothing has to be refused here rather than carried on
        ;; with as a pane that does not exist.
        (user-error "No row of that name"))))

(defun herdr-panel--table (rows)
  "Return a completion table over ROWS that does not reorder them."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (category . herdr-pane)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action rows string predicate))))

(defun herdr-panel--distinct (rows)
  "Return ROWS with no two lines alike.
Two panes can draw one line between them: two agents of a kind, in one
window, reporting the same title.  A table holding a line twice sends
both to whichever pane came first, so every row of a repeated line is
named by its pane, which is the one thing about it that cannot repeat.
Every one of them, rather than all but the first: a line singled out
among identical ones says the others are something else."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (row rows)
      (puthash (car row) (1+ (gethash (car row) counts 0)) counts))
    (mapcar (lambda (row)
              (if (eql (gethash (car row) counts) 1)
                  row
                (cons (concat (car row) " "
                              (herdr-panel-text (cdr row)
                                                'herdr-panel-detail))
                      (cdr row))))
            rows)))

;;; Keys

(defvar-keymap herdr-panel-mode-map
  :doc "Keymap shared by the herdr panels."
  :parent magit-section-mode-map
  "RET" #'herdr-panel-visit
  ;; The up event, so that dragging to select text still selects it:
  ;; a drag ends in `drag-mouse-1' and never reaches this.  Only the
  ;; double click is spoken for upstream, where magit-section toggles a
  ;; section with it.
  "<mouse-1>" #'herdr-panel-visit-click
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
           (herdr-panel--buffer-pane buffer))
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
  ;; Ahead of that redraw on the same hook, so a row that has just begun
  ;; wanting the user is already pulsing by the time it is drawn.
  (add-hook 'herdr-session-change-hook #'herdr-panel--note-attention -50)
  (add-hook 'window-selection-change-functions #'herdr-panel--note-marks)
  (add-hook 'window-selection-change-functions
            #'herdr-panel-track-point-everywhere)
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
    (remove-hook 'herdr-session-change-hook #'herdr-panel--note-attention)
    (remove-hook 'window-selection-change-functions #'herdr-panel--note-marks)
    (remove-hook 'window-selection-change-functions
                 #'herdr-panel-track-point-everywhere)
    (remove-hook 'window-buffer-change-functions #'herdr-panel--note-marks)
    (remove-hook 'herdr-session-fingerprint-functions #'herdr-panel-marks)
    (herdr-panel--pulse-forget)))

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

(defun herdr-panel-open-pane (pane &optional access)
  "Show the terminal for PANE and move to it.
ACCESS is `control' to open a terminal that takes what is typed at it,
and `observe' or nil to open one that only shows the pane.  Only one
client at a time holds control of a pane, so a panel visiting a row
observes: browsing a list of panes is not a reason to take control of
each in turn.
The terminal replaces whatever the main window held, rather than
splitting or taking over the panel: a panel is furniture, and a layout
that rearranged itself every time a row was visited would be worse
than one window showing one pane.

Selecting the terminal is what herdr does when a row is activated, and
here it also moves the panels' own highlight onto the row just
visited, because that highlight follows the selected window."
  (require 'herdr-term)
  ;; Going to a pane on purpose is reading whatever it finished.  Nothing
  ;; else clears the mark, because a pane sits on screen for as long as
  ;; anybody works in the layout and clearing on that would clear at once.
  (herdr-session-mark-seen pane)
  (let ((display-buffer-overriding-action
         '((herdr-panel--display-in-main))))
    (herdr-term-open pane (eq access 'control)))
  (when-let* ((buffer (seq-find (lambda (buffer)
                                  (equal (herdr-panel--buffer-pane buffer)
                                         pane))
                                (buffer-list))))
    ;; A terminal already on screen is shown as it stands, so asking for
    ;; control has to say so again here.  Otherwise a pane first opened
    ;; from a panel that was only reading would go on ignoring what was
    ;; typed at it however often it was visited.
    (when (and (eq access 'control)
               (not (buffer-local-value 'herdr-term--writable buffer)))
      (with-current-buffer buffer
        (herdr-term-take-control)))
    (when-let* ((window (get-buffer-window buffer)))
      (select-window window))))

;;; _
(provide 'herdr-panel)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-panel.el ends here
