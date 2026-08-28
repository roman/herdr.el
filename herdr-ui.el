;;; herdr-ui.el --- The herdr window layout  -*- lexical-binding:t -*-

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

;; The herdr layout in one command: a column of panels down the left, and
;; a terminal filling the rest.  The panels go in side windows, so that
;; ordinary display of a file or a help buffer cannot land in one of them
;; and `delete-other-windows' in the terminal leaves the layout standing.

;; What the column holds is `herdr-ui-panels': spaces, then agents, then
;; reviews.  Reviews is optional, because `herdr-review' needs a tool herdr
;; does not, so its entry is skipped until that file is loaded.

;; The tabs of the terminal's workspace ride on its tab line rather than
;; in a window of their own.  A window would cost a mode line and a border
;; to show one row of labels, and Emacs already puts tabs on the tab line,
;; which is where a reader looks for them.

;; The commands that make, close, rename and walk those tabs are here too,
;; because each of them means the tab of the pane a terminal mirrors and
;; the tab line is what shows the result.  None asks herdr to focus what
;; it made.  This Emacs is a program in a herdr pane, so herdr's focus
;; decides where the keyboard goes, and a command that moved it would take
;; the keyboard out of Emacs.  Splitting a pane lives in `herdr-term',
;; which owns the terminal a split comes off.

;;; Code:

(require 'seq)
(require 'tab-line)

(require 'herdr-agents)
(require 'herdr-api)
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
              #'herdr-ui-toggle-panels)
  ;; The tab commands answer in a terminal and nowhere else: the tab one
  ;; of them means is the tab of the pane that terminal mirrors.
  (keymap-set herdr-term-command-mode-map "C-c C-t" #'herdr-ui-tab-new)
  (keymap-set herdr-term-command-mode-map "C-c C-n" #'herdr-ui-tab-next)
  (keymap-set herdr-term-command-mode-map "C-c C-p" #'herdr-ui-tab-previous)
  (keymap-set herdr-term-command-mode-map "C-c C-r" #'herdr-ui-tab-rename)
  (keymap-set herdr-term-command-mode-map "C-c C-d" #'herdr-ui-tab-close))

;;; Options

(defcustom herdr-ui-side-width 32
  "Width in columns of the column holding the panels."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'natnum)

(defcustom herdr-ui-panels
  '((herdr-spaces-panel . 3)
    (herdr-agents-panel . 2)
    (herdr-review-panel . 1))
  "The panels stacked in the column, top to bottom.
Each entry is (FUNCTION . WEIGHT).  FUNCTION takes no arguments and
returns the panel's buffer, drawn and tracking the session; WEIGHT is
that panel's share of the column, counted against the weights of the
other panels rather than as a fraction, so that leaving one out leaves
the rest in proportion.  Spaces outweighs agents because it lists every
workspace, while agents lists only the panes herdr found one running
in, and reviews is smaller again because it holds a row per workspace
under review and usually none.

An entry whose function is undefined is skipped rather than an error,
which is how an optional panel keeps its place in the order without
costing anything.  Reviews is one: `herdr-review' is not loaded with the
rest of herdr, because it needs a tool herdr does not."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(alist :key-type function :value-type number))

(make-obsolete-variable 'herdr-ui-spaces-height 'herdr-ui-panels
                        "herdr 0.1.0")

(declare-function herdr-review-panel "herdr-review" ())

(defcustom herdr-ui-panel-other-window 'skip
  "Whether `other-window' stops on a panel.
`skip' takes the panel column out of the cycle, so \\[other-window]
and everything built on it move between the windows you work in and
pass the furniture by.  A panel is still reached by the command that
names it — `herdr-spaces', `herdr-agents', `herdr-review', the visit
commands they each offer, and `herdr-ui-toggle-panels' from inside the
layout — and still by the mouse.

`stop' leaves the panels in the cycle, which is what any other window
does.

Only the cycle is affected.  `ignore-window-parameters' bound around a
call reaches a skipped window once without changing this."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type '(choice (const :tag "Pass the panels by" skip)
                 (const :tag "Stop on them like any window" stop)))

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
  "Put the panels of `herdr-ui-panels' in their column, in order.
An entry whose function is not defined is left out, and the weights of
the rest are shared over what is left."
  ;; `functionp' rather than `fboundp', which signals on anything but a
  ;; symbol: an entry may be a function rather than a name for one.
  (let* ((panels (seq-filter (lambda (panel) (functionp (car panel)))
                             herdr-ui-panels))
         (total (float (apply #'+ 0 (mapcar #'cdr panels))))
         (slot 0))
    (dolist (panel panels)
      (herdr-ui--display (funcall (car panel)) slot (/ (cdr panel) total))
      (setq slot (1+ slot)))))

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
     (window-parameters
      . ((no-delete-other-windows . t)
         (no-other-window . ,(eq herdr-ui-panel-other-window 'skip)))))))

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

;;;###autoload
(defun herdr-ui-quit ()
  "Take the herdr panels off the frame and stop tracking the session.
Every panel goes, including one from a package this file knows nothing
about, because what is left behind would keep asking the session for a
redraw that no longer comes.  Terminals stay: a buffer mirroring a
pane is work in progress, not furniture."
  (interactive)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'herdr-panel-refresh-function buffer)
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
                         (herdr-session-status tab))
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
  (let ((pane (herdr-ui--tab-pane tab-id)))
    (unless pane
      (user-error "Tab %s has no pane" tab-id))
    (herdr-panel-open-pane pane)))

(defun herdr-ui--tab-pane (tab)
  "Return the first pane of TAB, or nil.
The session tree answers when it has TAB, and herdr itself when it does
not, for the reason `herdr-ui--pane-node' gives.  Stepping onto a tab
made a keystroke ago reaches this before any event has refreshed the
tree, and reading the tree alone refused to open the tab it had just
been asked for."
  (or (gethash "pane_id" (or (car (herdr-session-panes tab))
                             (make-hash-table :size 1)))
      (car (herdr-ui--panes tab))))

(defun herdr-ui--panes (tab)
  "Return the identifiers of TAB's panes, as herdr reports them now."
  (let ((panes (gethash "panes" (herdr-api-request "pane.list"))))
    (delq nil
          (mapcar (lambda (pane)
                    (and (equal (gethash "tab_id" pane) tab)
                         (gethash "pane_id" pane)))
                  (or panes [])))))

;;; Reaching Any Terminal Of The Session

;; One prompt over every pane, which no single panel can offer: a Spaces
;; row leads to the pane of its workspace's active tab, and an Agents row
;; exists only where herdr recognised something running.  A shell split
;; off another pane is in neither.

;; The row is built here rather than in either panel because it takes from
;; both — the workspace and its checkout from Spaces, the agent's glyph
;; from Agents — and this file is where they already meet.

;;;###autoload
(defun herdr-ui-visit-pane (pane &optional other)
  "Show the terminal for PANE, read over every pane of the session.
With a prefix argument OTHER, open it the other way round from
`herdr-panel-visit-access', as the panels' own visit commands do."
  (interactive (list (herdr-ui--read-pane) current-prefix-arg))
  (herdr-panel-open-pane pane (herdr-panel-access other)))

(defun herdr-ui--read-pane ()
  "Read a pane of the session with completion and return it.
Rows run in the order herdr reports the panes, which keeps the panes
of one workspace together."
  (herdr-panel-read-nodes "Terminal: "
                          #'herdr-session-panes
                          #'herdr-ui--pane-entry
                          "Herdr reports no pane to visit"))

(defun herdr-ui--pane-entry (pane current)
  "Return the row for PANE, emphasised against the CURRENT one.
The status mark opens the row, then the workspace and the pane's own
identifier, then the agent as its glyph alone.  The glyph carries the
kind on its own, so spelling the name beside it would say one thing
twice in a row that has to stay readable at a glance."
  (list :status (herdr-session-status pane)
        :emphasis (herdr-panel-emphasis (gethash "pane_id" pane) current)
        :id (gethash "pane_id" pane)
        :label (herdr-ui--pane-label pane)
        :aside (herdr-agents-glyph pane)
        :detail (herdr-ui--pane-detail pane)))

(defun herdr-ui--pane-label (pane)
  "Return the workspace PANE belongs to, with PANE's own name beside it.
The workspace says which checkout, and the identifier tells two panes
of it apart.  A workspace herdr no longer reports leaves the
identifier standing alone, which still names the pane."
  (let* ((workspace (herdr-session-workspace (gethash "workspace_id" pane)))
         (label (and workspace (gethash "label" workspace)))
         (id (gethash "pane_id" pane)))
    (if label (format "%s (%s)" label id) id)))

(defun herdr-ui--pane-detail (pane)
  "Return the line that follows PANE's name: where the terminal sits.
The branch and the working tree are left to the Spaces panel.  They
are the same for every pane of one checkout, so in a list of terminals
they repeat down the column without telling any two of them apart.
The face is what sorts this into the prompt's location column."
  (let* ((directory (gethash "cwd" pane))
         (parts (delq nil (list (and directory
                                     (herdr-panel-text
                                      (abbreviate-file-name directory)
                                      'herdr-panel-path))
                                (herdr-panel-tab-name pane)))))
    (and parts (list (string-join parts " ")))))


(defun herdr-ui--read-tab ()
  "Read a tab of the session with completion."
  (let ((tabs (mapcar (lambda (tab) (gethash "tab_id" tab))
                      (herdr-session-tabs))))
    (unless tabs
      (user-error "Herdr reports no tabs"))
    (completing-read "Tab: " tabs nil t)))

;;; Tabs Of The Terminal's Workspace

;; The tab line draws these, and every command here is reached from a
;; terminal buffer, because the tab a command means is the tab of the
;; pane that buffer mirrors.  None of them asks herdr to focus what it
;; made.  This Emacs is a program in a herdr pane, so herdr's focus is
;; what decides where the keyboard goes, and a command that moved it
;; would take the keyboard out of Emacs.  Emacs shows the new tab in a
;; window of its own instead.

(defun herdr-ui--this-pane ()
  "Return the pane this buffer mirrors, or refuse when it mirrors none.
Read through `herdr-panel--buffer-pane', which answers nil rather than
signalling in an Emacs where the terminal was never loaded."
  (or (herdr-panel--buffer-pane (current-buffer))
      (user-error "This buffer mirrors no herdr pane")))

(defun herdr-ui--pane-node (pane)
  "Return what herdr knows about PANE, or nil.
The session tree answers when it has PANE, and herdr itself when it
does not.  The tree is refreshed from an event a moment after the
change that raised it, so a pane made a keystroke ago is not in it yet,
and a command that read the tree alone would refuse to act on the very
pane it was just given."
  (or (herdr-session-pane pane)
      (gethash "pane" (herdr-api-request "pane.get" (list :pane_id pane)))))

(defun herdr-ui--this-node ()
  "Return what herdr knows about the pane this buffer mirrors.
One lookup answers for both the tab and the workspace, so a command
wanting each of them spends one call and not two."
  (let ((pane (herdr-ui--this-pane)))
    (or (herdr-ui--pane-node pane)
        (user-error "Herdr reports nothing for pane %s" pane))))

(defun herdr-ui--this-tab ()
  "Return the tab holding the pane this buffer mirrors."
  (gethash "tab_id" (herdr-ui--this-node)))

(defun herdr-ui--this-workspace ()
  "Return the workspace holding the pane this buffer mirrors."
  (gethash "workspace_id" (herdr-ui--this-node)))

;;;###autoload
(defun herdr-ui-tab-new (&optional label)
  "Create a tab in this terminal's workspace and show its pane.
With a prefix argument, LABEL names the tab; otherwise herdr numbers
it.  The new pane runs a shell in the workspace's own directory."
  (interactive (list (when current-prefix-arg
                       (read-string "New tab label: "))))
  (let* ((result (herdr-api-request
                  "tab.create"
                  (append (list :workspace_id (herdr-ui--this-workspace))
                          (when label (list :label label)))))
         (root (gethash "root_pane" result))
         (pane (and root (gethash "pane_id" root))))
    ;; The call itself succeeded; herdr just answered with a shape this
    ;; command cannot use, which is ours to report, not the API's.
    (unless pane
      (user-error "Herdr created a tab but named no pane in it"))
    (herdr-panel-open-pane pane 'control)))

;;;###autoload
(defun herdr-ui-tab-close ()
  "Close this terminal's tab in herdr, and every pane in it.
The tab goes for every client of the session, and herdr closes a
workspace along with its last tab."
  (interactive)
  (let ((tab (herdr-ui--this-tab)))
    (unless (y-or-n-p (format "Close herdr tab %s and its panes? " tab))
      (user-error "Tab %s left alone" tab))
    ;; The panes are read before the tab goes, because afterwards herdr
    ;; reports none for it and there would be no way left to say which
    ;; buffers mirrored it.
    (let ((panes (herdr-ui--panes tab)))
      (herdr-api-request "tab.close" (list :tab_id tab))
      ;; A stream whose pane has gone takes its buffer down on its own,
      ;; under `herdr-term-pane-gone-action'.  Doing it here as well is
      ;; what makes the buffers go with the tab rather than a moment
      ;; later, which is how \\[herdr-term-kill-pane] behaves too.
      (dolist (buffer (buffer-list))
        ;; A local binding, not merely a value: `buffer-local-value'
        ;; answers with the global one for a buffer that has none, so a
        ;; test or a stray `setq' that left it non-nil would otherwise
        ;; match every buffer in the session.
        (when (and (local-variable-p 'herdr-term--pane buffer)
                   (member (herdr-panel--buffer-pane buffer) panes))
          (kill-buffer buffer))))))

;;;###autoload
(defun herdr-ui-tab-rename (label)
  "Rename this terminal's tab to LABEL.
The name replaces the number on the tab line, here and in herdr's own
window."
  (interactive (list (read-string "Rename tab to: ")))
  (herdr-api-request "tab.rename"
                     (list :tab_id (herdr-ui--this-tab) :label label)))

;;;###autoload
(defun herdr-ui-tab-next ()
  "Show the next tab of this terminal's workspace, wrapping at the last."
  (interactive)
  (herdr-ui--step-tab #'identity))

;;;###autoload
(defun herdr-ui-tab-previous ()
  "Show the previous tab of this terminal's workspace, wrapping at the first."
  (interactive)
  (herdr-ui--step-tab #'reverse))

(defun herdr-ui--step-tab (order)
  "Show the tab beside this one, ORDER choosing the direction.
ORDER is `identity' to move forward and `reverse' to move back, so one
walk serves both directions."
  (let* ((node (herdr-ui--this-node))
         (tab (gethash "tab_id" node))
         (tabs (funcall order
                        (herdr-ui--tabs (gethash "workspace_id" node)))))
    (unless (cdr tabs)
      (user-error "Herdr reports no tab beside %s" tab))
    (herdr-ui-visit-tab (or (cadr (member tab tabs)) (car tabs)))))

(defun herdr-ui--tabs (workspace)
  "Return the identifiers of WORKSPACE's tabs, in the order herdr has them.
Asked of herdr rather than read from the session tree, for the reason
`herdr-ui--pane-node' gives: a tab made a keystroke ago is not in the
tree yet, and a walk that read it would step straight past the tab it
was just asked to make."
  (let ((tabs (gethash "tabs" (herdr-api-request
                               "tab.list"
                               (list :workspace_id workspace)))))
    (mapcar (lambda (node) (gethash "tab_id" node)) (or tabs []))))

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
