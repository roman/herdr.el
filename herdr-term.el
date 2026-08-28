;;; herdr-term.el --- Mirror a herdr-owned pane  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes terminals

;; Package-Version: 0.1.0
;; Package-Requires: (
;;     (emacs   "29.1")
;;     (ghostel "0.48"))

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

;; Render a pane owned by the herdr server into a ghostel buffer, driven by
;; the `herdr terminal session observe' and `herdr terminal session control'
;; command line bridges.  Both ends run libghostty-vt, so content and style
;; survive with no fidelity loss.

;; The stream is newline delimited JSON:
;;
;;   {"type":"terminal.frame","seq":N,"full":BOOL,"width":W,"height":H,
;;    "bytes":"<base64 ANSI>"}
;;   {"type":"terminal.closed","reason":...}
;;
;; herdr sends one `full' frame on connect, a complete repaint and the only
;; authoritative resync point, then `full:false' deltas relative to the
;; previously composed frame, each stamped with an incrementing `seq'.  A
;; client that drops or misorders one delta diverges permanently, and the
;; protocol has no "request full frame" command, so the only resync is to
;; reconnect.  This module therefore treats a full frame as a hard reset,
;; refuses a delta that arrives before one, and reconnects on any `seq' gap
;; or unexpected stream exit.

;; herdr owns the pane, and with it the grid: every dimension this module
;; renders comes from a frame.  Nothing here resizes the terminal on its own
;; initiative, and ghostel's own window-driven resize is disowned, because a
;; local resize would leave the grid disagreeing with the frames still
;; arriving for it and no `seq' gap would mark the divergence.

;; Input reaches herdr through ghostel's own PTY sink rather than through
;; rebound keys, so that every ghostel and evil-ghostel input path works
;; alike.  See `herdr-term--ensure-input-bridge'.

;; Only the frame stream uses the command line, because it is the one
;; thing the JSON API does not carry.  Everything structural, such as
;; listing panes or creating a workspace, goes through `herdr-api'.

;; Splitting a pane, ending one and walking between the panes of a tab are
;; here, because each acts on the pane a terminal mirrors.  A split is
;; made unfocused: this Emacs is itself a program in a herdr pane, so
;; moving herdr's focus onto the new pane would send the keyboard there
;; and take it away from Emacs.  The window opened beside the old one
;; takes what is typed instead.  Tabs are `herdr-ui', which draws them.

;;; Code:

(require 'ghostel)
(require 'seq)

(require 'herdr-api)
(require 'herdr-session)

;;; Options

(defgroup herdr-term nil
  "Mirror a herdr-owned pane in an Emacs buffer."
  :group 'processes
  :prefix "herdr-term-")

(defcustom herdr-term-executable "herdr"
  "The herdr executable used to stream a pane's frames.
Only the frame stream runs herdr as a command; see `herdr-api-socket'
for the socket everything else uses.  A relative name is resolved
against the variable `exec-path' at the moment it is run, so
installing herdr later needs no reconfiguration."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'string)

(defcustom herdr-term-reconnect-min-interval 0.4
  "Minimum number of seconds between reconnects of one stream.
A reconnect requested sooner than this is deferred, never dropped."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'number)

(defcustom herdr-term-pane-gone-action 'kill
  "What becomes of a terminal buffer whose pane herdr no longer has.
A pane that has gone is not a stream that dropped: reconnecting to it
can never succeed, so the buffer stops retrying whichever this is.  This
only says what happens to the buffer afterwards.

`kill' removes it, as herdr removed the pane.  `keep' leaves the last
frame readable and marks the mode line closed, which is what you want
when a review or a command wrote something you still need to read."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type '(choice (const :tag "Kill the buffer" kill)
                 (const :tag "Keep it, marked closed" keep)))

(defcustom herdr-term-scroll-lines 3
  "How many lines one wheel notch scrolls the pane.
This matches herdr's own mouse scroll default, so a pane moves by the
same amount whether it is scrolled from Emacs or from the herdr TUI."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'natnum)

(defcustom herdr-term-resize-delay 0.2
  "Seconds to wait for a window to settle before resizing its pane.
Dragging a window edge reports every intermediate size, and each would
otherwise cost a resize and the full repaint that follows it."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'number)

(defcustom herdr-term-max-connect-attempts 3
  "How many times to retry a stream that exits without ever syncing.
This bounds recovery for a pane id that is invalid or has vanished,
which would otherwise be retried forever."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-term
  :type 'natnum)

;;; Variables

(defconst herdr-term--scroll-limit 65535
  "Largest line count `terminal.scroll' accepts, its `lines' being a u16.")

(defvar-local herdr-term--process nil
  "Process running this buffer's frame stream.")

(defvar-local herdr-term--stdout ""
  "Trailing partial line of stream output, awaiting its newline.")

(defvar-local herdr-term--pane nil
  "Identifier of the herdr pane this buffer mirrors.")

(defvar-local herdr-term--writable nil
  "Non-nil when the stream is `control', which accepts input.")

(defvar-local herdr-term--last-seq nil
  "Sequence number of the last applied frame.
Nil before the current connection has applied its first full frame,
which makes it the record of whether that connection ever synced.")

(defvar-local herdr-term--rows nil
  "Number of rows in the grid herdr last reported for this pane.")

(defvar-local herdr-term--cols nil
  "Number of columns in the grid herdr last reported for this pane.")

(defvar-local herdr-term--last-reconnect nil
  "Value of `float-time' when this buffer last started a stream.")

(defvar-local herdr-term--reconnect-timer nil
  "Timer of a deferred reconnect, or nil when none is pending.")

(defvar-local herdr-term--fail-count 0
  "Number of successive connections that exited without ever syncing.")

(defvar-local herdr-term--close-reason nil
  "Reason reported by the last `terminal.closed' of the current stream.")

(defvar-local herdr-term--pane-gone nil
  "Non-nil once herdr reported this buffer's pane as no longer existing.")

(defvar-local herdr-term--input-bridge nil
  "Process forwarding ghostel's PTY writes to the control stream.")

(defvar-local herdr-term--resize-timer nil
  "Timer of a pending resize, or nil when none is due.")

;;; Keymaps

;; The shifted page keys are what a terminal emulator conventionally uses
;; for its own scrollback, which leaves the unshifted ones to reach the
;; program running in the pane.
(defvar-keymap herdr-term-command-mode-map
  :doc "Keymap for `herdr-term-command-mode'."
  "C-g" #'keyboard-quit
  "C-c C-g" #'herdr-term-send-control-g
  "C-c C-l" #'herdr-term-resync
  "C-c C-k" #'herdr-term-close
  "C-c C-w" #'herdr-term-take-control
  "C-c C-e" #'herdr-term-scroll-to-bottom
  ;; The digits are the shape of the split, as they are in the window
  ;; commands every Emacs user already has: 2 divides the window across,
  ;; 3 divides it down the middle.
  "C-c C-2" #'herdr-term-split-down
  "C-c C-3" #'herdr-term-split-right
  "C-c C-o" #'herdr-term-other-pane
  "C-c C-x" #'herdr-term-kill-pane
  "S-<prior>" #'herdr-term-scroll-page-up
  "S-<next>" #'herdr-term-scroll-page-down
  "<wheel-up>" #'herdr-term-scroll-up
  "<wheel-down>" #'herdr-term-scroll-down)

(declare-function evil-define-minor-mode-key "evil-core"
                  (state mode key def &rest bindings))
(declare-function ghostel--send-event "ghostel" ())

(defconst herdr-term-evil-passthrough-keys
  '("<escape>" "DEL" "<backspace>" "C-a" "C-d" "C-e" "C-k" "C-n"
    "C-p" "C-q" "C-r" "C-t" "C-v" "C-w")
  "Keys insert state must hand to the program rather than act on.
evil binds these for editing a buffer, and its state maps outrank both
the major and the minor mode maps, so ghostel never sees them: in a
terminal that makes backspace do nothing and takes the shell's own
line editing away.  Escape is here for the same reason and not to
leave insert state: a pane always holds a program that reads it, an
agent or an editor or a pager.  `C-o' and `C-z' are deliberately left
to evil, as the way back out of a terminal that has the keyboard.")

;; Registered against the minor mode rather than defined on its keymap,
;; because evil ranks a minor mode's keymaps above the auxiliary ones
;; `evil-define-key*' builds, and a herdr buffer is very likely to have
;; evil-ghostel in it.  That package claims escape and the control keys
;; on auxiliary maps of its own, and routes escape to the terminal only
;; while ghostel reports an alternate screen — which a herdr pane never
;; does, because the frames herdr sends have the mode flattened out of
;; them.  Ranking above it is what makes the routing the same in every
;; pane.  Either way the bindings live and die with the mode, so they
;; cannot outlast a herdr buffer.
;;
;; The motions are normal state only: insert state is where keys reach
;; the program, so binding one there would swallow it.
(with-eval-after-load 'evil
  (apply #'evil-define-minor-mode-key 'insert 'herdr-term-command-mode
         (mapcan (lambda (key) (list (kbd key) #'ghostel--send-event))
                 herdr-term-evil-passthrough-keys))
  (evil-define-minor-mode-key 'insert 'herdr-term-command-mode
                              (kbd "C-g") #'keyboard-quit
                              (kbd "C-c C-g")
                              #'herdr-term-send-control-g)
  (evil-define-minor-mode-key 'normal 'herdr-term-command-mode
                              "j" #'herdr-term-line-down
                              "k" #'herdr-term-line-up
                              (kbd "C-e") #'herdr-term-scroll-down
                              (kbd "C-y") #'herdr-term-scroll-up
                              (kbd "C-f") #'herdr-term-scroll-page-down
                              (kbd "C-b") #'herdr-term-scroll-page-up
                              (kbd "C-d") #'herdr-term-scroll-half-page-down
                              (kbd "C-u") #'herdr-term-scroll-half-page-up
                              "gg" #'herdr-term-scroll-to-top
                              "G" #'herdr-term-scroll-to-bottom))

;;; Commands

;;;###autoload
(defun herdr-term-open (pane &optional writable)
  "Open a buffer mirroring herdr PANE.
With a prefix argument WRITABLE, attach the `control' stream so that
keystrokes reach the pane; otherwise attach `observe', which is read
only.  Re-opening a pane that is already streaming only displays its
buffer, because re-initializing would tear down a working terminal."
  (interactive
   (list (herdr-term-read-pane "Open pane: ") current-prefix-arg))
  (ghostel--load-module t)
  (let* ((name (herdr-term--buffer-name pane))
         (existing (herdr-term--buffer pane)))
    (when (and existing (not (equal (buffer-name existing) name)))
      (with-current-buffer existing
        (rename-buffer name t)))
    (if (and existing
             (process-live-p
              (buffer-local-value 'herdr-term--process existing)))
        (pop-to-buffer existing)
      (herdr-term--setup (or existing (get-buffer-create name))
                         pane writable))))

;;;###autoload
(defun herdr-term-new (&optional cwd)
  "Create a herdr terminal in CWD and open it writable.
This creates a herdr workspace whose root pane runs a shell, then
attaches a `control' stream to that pane, which is how a terminal is
driven from Emacs.  Interactively, a prefix argument prompts for CWD;
otherwise `default-directory' is used, falling back to the home
directory when the current buffer is remote."
  (interactive (list (when current-prefix-arg
                       (read-directory-name "New terminal cwd: "))))
  (let* ((directory
          (expand-file-name
           (or cwd (if (file-remote-p default-directory)
                       "~"
                     default-directory))))
         (result (herdr-api-request "workspace.create"
                                    (list :cwd directory)))
         (root (gethash "root_pane" result))
         (pane (and root (gethash "pane_id" root))))
    ;; The call itself succeeded; herdr just answered with a shape this
    ;; command cannot use, which is ours to report, not the API's.
    (unless pane
      (user-error "Herdr created no pane for %s" directory))
    (herdr-term-open pane t)))

;;;###autoload
(defun herdr-term-split-right ()
  "Split this terminal's pane in herdr and open the new one beside it."
  (interactive)
  (herdr-term--split "right"))

;;;###autoload
(defun herdr-term-split-down ()
  "Split this terminal's pane in herdr and open the new one below it."
  (interactive)
  (herdr-term--split "down"))

(defun herdr-term--split (direction)
  "Split the pane this buffer mirrors, to the DIRECTION of it.
DIRECTION is \"right\" or \"down\", the two herdr splits on.  The new
pane runs a shell in the directory the split pane is in, which is what
herdr starts one in when the request names no other.

herdr is not asked to focus the new pane.  This Emacs is itself a
program in a herdr pane, so moving herdr's focus would send the
keyboard to the new pane and take it away from Emacs.  The window
opened here takes what is typed instead."
  (let* ((pane (herdr-term--this-pane))
         (result (herdr-api-request "pane.split"
                                    (list :target_pane_id pane
                                          :direction direction)))
         (created (gethash "pane" result))
         (new (and created (gethash "pane_id" created))))
    ;; The call itself succeeded; herdr just answered with a shape this
    ;; command cannot use, which is ours to report, not the API's.
    (unless new
      (user-error "Herdr split %s but named no pane" pane))
    (herdr-term--open-beside new direction)))

(defun herdr-term--open-beside (pane direction)
  "Open PANE in a window split off this one, to the DIRECTION of it.
The terminal is opened with control, because a pane split off the one
being worked in is one to work in rather than one to watch.

The window is marked as one this command made, which is what lets
\\[herdr-term-kill-pane] take it down again without touching a window
that was already there."
  (let ((window (if (equal direction "right")
                    (split-window-right)
                  (split-window-below)))
        (was (selected-window)))
    (set-window-parameter window 'herdr-term-split t)
    (let ((display-buffer-overriding-action
           (list (lambda (buffer _alist)
                   (set-window-buffer window buffer)
                   window))))
      (herdr-term-open pane t))
    (select-window window)
    ;; Both windows are new sizes, and the hook that notices a resize
    ;; runs from redisplay, which a command rearranging windows does not
    ;; always reach.  A terminal left unfitted draws into a fraction of
    ;; the width it now has.
    (herdr-term--note-resize was)
    (herdr-term--note-resize window)))

(defun herdr-term--this-pane ()
  "Return the pane this buffer mirrors, or refuse when it mirrors none."
  (or herdr-term--pane
      (user-error "This buffer mirrors no herdr pane")))

;;;###autoload
(defun herdr-term-kill-pane ()
  "End the herdr pane this buffer mirrors, then close the buffer.
The pane ends for every client of the session and the program in it
goes with it, which is what separates this from
\\[herdr-term-close], where only this Emacs stops looking.  herdr
closes a tab along with its last pane, and a workspace along with its
last tab, so this can take more than the pane named."
  (interactive)
  (let ((pane (herdr-term--this-pane)))
    (unless (y-or-n-p (format "End herdr pane %s? " pane))
      (user-error "Pane %s left alone" pane))
    (herdr-api-request "pane.close" (list :pane_id pane))
    (let ((window (selected-window)))
      (kill-buffer)
      ;; Only a window this package split off another goes with the pane
      ;; in it.  The main window of a herdr layout holds whichever pane
      ;; is being worked in and was not opened for this one, so deleting
      ;; it would take the layout apart.
      (when (and (window-live-p window)
                 (window-parameter window 'herdr-term-split)
                 (not (one-window-p)))
        (delete-window window)))))

;;;###autoload
(defun herdr-term-other-pane ()
  "Show the next pane of this terminal's tab, wrapping at the last.
Only panes of one tab are walked.  Another tab is reached by its own
commands, and a pane elsewhere in the session by the panels."
  (interactive)
  (let* ((pane (herdr-term--this-pane))
         (siblings (herdr-term--tab-panes pane)))
    (unless (cdr siblings)
      (user-error "Pane %s is the only one in its tab" pane))
    (herdr-term--show-here (herdr-term--after pane siblings))))

(defun herdr-term--show-here (pane)
  "Open PANE with control in the window the current one is in.
Walking to a sibling replaces what is being looked at rather than
splitting the frame again, which is what `pop-to-buffer' would do
inside a herdr layout."
  (let* ((window (selected-window))
         (display-buffer-overriding-action
          (list (lambda (buffer _alist)
                  (set-window-buffer window buffer)
                  window))))
    (herdr-term-open pane t))
  ;; `herdr-term-open' shows a terminal that is already streaming as it
  ;; stands, so control has to be asked for again here.  A sibling first
  ;; opened from a panel observes, and would go on ignoring what is
  ;; typed at it however often it was walked to.
  (when-let* ((buffer (herdr-term--buffer pane))
              ((not (buffer-local-value 'herdr-term--writable buffer))))
    (with-current-buffer buffer
      (herdr-term-take-control)))
  (herdr-term--note-resize (selected-window)))

(defun herdr-term--tab-panes (pane)
  "Return the identifiers of every pane sharing PANE's tab, in order.
Asked of herdr rather than read from the session tree.  The tree is
refreshed from an event a moment after the change that raised it, so a
split made here is not in it yet, and a walk that read it would report
the pane just made as the only one in its tab."
  (let ((panes (herdr-term--panes)))
    (when-let* ((info (cdr (assoc pane panes)))
                (tab (gethash "tab_id" info)))
      (delq nil
            (mapcar (lambda (entry)
                      (and (equal (gethash "tab_id" (cdr entry)) tab)
                           (car entry)))
                    panes)))))

(defun herdr-term--after (item items)
  "Return what follows ITEM in ITEMS, or the first when it is last."
  (let ((rest (cdr (member item items))))
    (or (car rest) (car items))))

(defun herdr-term-send-control-g ()
  "Send a literal control-G byte to the program in the pane."
  (interactive)
  (herdr-term--send-input "\C-g"))

(defun herdr-term-resync ()
  "Force a full-frame resync of the current buffer.
This also clears a previous give-up, and a pane reported gone, so a
stream abandoned after `herdr-term-max-connect-attempts' — or one whose
pane herdr has since made again under the same id — can be retried."
  (interactive)
  (setq herdr-term--last-reconnect nil
        herdr-term--fail-count 0)
  (herdr-term--reconnect "manual"))

(defun herdr-term-close ()
  "Kill this buffer, and with it its stream."
  (interactive)
  (kill-buffer (current-buffer)))

(defun herdr-term-scroll-up ()
  "Scroll this pane back through its history by one wheel notch.
The distance is `herdr-term-scroll-lines'."
  (interactive)
  (herdr-term--scroll "up" herdr-term-scroll-lines))

(defun herdr-term-scroll-down ()
  "Scroll this pane forward through its history by one wheel notch.
The distance is `herdr-term-scroll-lines'."
  (interactive)
  (herdr-term--scroll "down" herdr-term-scroll-lines))

(defun herdr-term-scroll-page-up ()
  "Scroll this pane back through its history by a screenful."
  (interactive)
  (herdr-term--scroll "up" (herdr-term--page-lines)))

(defun herdr-term-scroll-page-down ()
  "Scroll this pane forward through its history by a screenful."
  (interactive)
  (herdr-term--scroll "down" (herdr-term--page-lines)))

(defun herdr-term-scroll-half-page-up ()
  "Scroll this pane back through its history by half a screenful."
  (interactive)
  (herdr-term--scroll "up" (max 1 (/ (herdr-term--page-lines) 2))))

(defun herdr-term-scroll-half-page-down ()
  "Scroll this pane forward through its history by half a screenful."
  (interactive)
  (herdr-term--scroll "down" (max 1 (/ (herdr-term--page-lines) 2))))

(defun herdr-term-line-up ()
  "Move up a line, scrolling the pane once the first one is reached.
The buffer only ever holds the pane's viewport, so there is no earlier
line to move onto; the pane has to bring one down instead."
  (interactive)
  (if (bobp)
      (herdr-term--scroll "up" 1)
    (forward-line -1)))

(defun herdr-term-line-down ()
  "Move down a line, scrolling the pane once the last one is reached.
The buffer only ever holds the pane's viewport, so there is no later
line to move onto; the pane has to bring one up instead."
  (interactive)
  (if (save-excursion (end-of-line) (eobp))
      (herdr-term--scroll "down" 1)
    (forward-line 1)))

(defun herdr-term-scroll-to-top ()
  "Show the start of this pane's history."
  (interactive)
  (herdr-term--scroll "up" herdr-term--scroll-limit))

(defun herdr-term-take-control ()
  "Reconnect this buffer's stream with control of its pane.
Scrolling and input both need control, and herdr grants it to one
client at a time, so this takes control from whoever holds it."
  (interactive)
  (when herdr-term--writable
    (user-error "Buffer already controls %s" herdr-term--pane))
  (setq herdr-term--writable t)
  (message "herdr-term[%s]: taking control" herdr-term--pane)
  (herdr-term-resync))

(defun herdr-term-scroll-to-bottom ()
  "Return this pane to the end of its history.
The distance asked for is deliberately larger than any scrollback, and
herdr clamps it, which saves asking the server where the bottom is."
  (interactive)
  (herdr-term--scroll "down" herdr-term--scroll-limit))

(define-minor-mode herdr-term-command-mode
  "Bind the client-local commands of a herdr terminal buffer.
These are the commands that act on the Emacs side of the mirror, such
as resync and close, as opposed to keys that are forwarded to the pane."
  :interactive nil)

;;; Setup and Teardown

(defun herdr-term--buffer (pane)
  "Return the terminal buffer mirroring PANE, or nil."
  (seq-find (lambda (buffer)
              (and (buffer-live-p buffer)
                   (equal (buffer-local-value 'herdr-term--pane buffer)
                          pane)))
            (buffer-list)))

(defun herdr-term--buffer-name (pane)
  "Return the terminal buffer name for PANE.
Put the agent title first so buffer lists distinguish work at a
glance, and retain PANE to keep equal titles unambiguous."
  (if-let* ((agent (herdr-session-agent pane))
            (title (herdr-session-agent-title agent)))
      (format "*herdr:%s [%s]*" title pane)
    (format "*herdr:%s*" pane)))

(defun herdr-term--rename-buffers ()
  "Update terminal buffer names from the current session titles."
  (dolist (buffer (buffer-list))
    (when-let* ((pane (and (buffer-live-p buffer)
                           (buffer-local-value 'herdr-term--pane buffer))))
      (let ((name (herdr-term--buffer-name pane)))
        (unless (equal (buffer-name buffer) name)
          (with-current-buffer buffer
            (rename-buffer name t)))))))

(add-hook 'herdr-session-change-hook #'herdr-term--rename-buffers)

(defun herdr-term--update-directory (buffer pane-id)
  "Update BUFFER's directory from PANE-ID in the current session tree."
  (when-let* ((pane (herdr-session-pane pane-id))
              (directory (gethash "cwd" pane))
              ((stringp directory))
              ((file-directory-p directory)))
    (with-current-buffer buffer
      (setq default-directory (file-name-as-directory directory)
            list-buffers-directory default-directory))))

(defun herdr-term--update-directories ()
  "Update terminal buffer directories from the current session tree."
  (dolist (buffer (buffer-list))
    (when-let* ((pane-id
                 (and (buffer-live-p buffer)
                      (buffer-local-value 'herdr-term--pane buffer))))
      (herdr-term--update-directory buffer pane-id))))

(add-hook 'herdr-session-change-hook #'herdr-term--update-directories)

(defun herdr-term--setup (buffer pane writable)
  "Display BUFFER, attach it to herdr PANE and start its stream.
WRITABLE selects the `control' stream over `observe'.  The grid is
first sized to the buffer's window so that the connect asks for
sensible dimensions; the first full frame then re-initializes it to
herdr's authoritative ones."
  (with-current-buffer buffer
    ;; Re-attaching to a buffer whose stream died leaves its processes and
    ;; timers running, and `ghostel-mode' is about to discard the variables
    ;; that still reference them.
    (herdr-term--teardown)
    (ghostel-mode))
  (pop-to-buffer buffer (append display-buffer--same-window-action
                                '((category . comint))))
  (let* ((window (get-buffer-window buffer t))
         (rows (if window
                   (max 1 (with-selected-window window
                            (floor (window-screen-lines))))
                 24))
         (cols (if window (max 1 (window-max-chars-per-line window)) 80)))
    (with-current-buffer buffer
      (setq herdr-term--pane pane
            herdr-term--writable writable
            herdr-term--last-seq nil
            herdr-term--last-reconnect nil
            herdr-term--fail-count 0)
      (herdr-term--update-directory buffer pane)
      (herdr-term--reset-term rows cols)
      (herdr-term-command-mode 1)
      (add-hook 'window-size-change-functions #'herdr-term--note-resize nil t)
      (add-hook 'kill-buffer-hook #'herdr-term--teardown nil t)
      (herdr-term--start-stream buffer)))
  buffer)

(defun herdr-term--teardown ()
  "Stop this buffer's stream, input bridge and pending reconnect."
  (herdr-term--kill-process)
  (herdr-term--cancel-reconnect)
  (herdr-term--cancel-resize)
  (herdr-term--kill-input-bridge))

;;; Stream Lifecycle

(defun herdr-term--start-stream (buffer)
  "Kill any stream attached to BUFFER and start a fresh one.
Return the new process.  A fresh connect always begins with a full
frame, so this doubles as the only resync the protocol offers."
  (with-current-buffer buffer
    (herdr-term--kill-process)
    (herdr-term--cancel-reconnect)
    (setq herdr-term--last-seq nil
          herdr-term--stdout ""
          herdr-term--close-reason nil
          herdr-term--pane-gone nil
          herdr-term--last-reconnect (float-time))
    (let* ((subcommand (if herdr-term--writable "control" "observe"))
           (arguments
            (append (list "terminal" "session" subcommand herdr-term--pane
                          "--rows" (number-to-string
                                    (or herdr-term--rows 24))
                          "--cols" (number-to-string
                                    (or herdr-term--cols 80)))
                    ;; Without `--takeover', `control' detaches at once,
                    ;; answering with a single `terminal.closed' and no
                    ;; frames at all.  We are the legitimate owner
                    ;; reconnecting to our own session, so always take over.
                    (and herdr-term--writable '("--takeover"))))
           (process (make-process
                     :name (format "herdr-term:%s" herdr-term--pane)
                     ;; Deliberately process-less: `process-send-string'
                     ;; resolves a nil process to the current buffer's, and
                     ;; ghostel's module falls back to exactly that call
                     ;; whenever `ghostel--process' is nil.  Adopting this
                     ;; process as the buffer's would let a stray keypress
                     ;; write raw bytes into a stream that speaks JSON.
                     :buffer nil
                     :command (cons herdr-term-executable arguments)
                     :connection-type 'pipe
                     :coding 'binary
                     :noquery t
                     :filter #'herdr-term--filter
                     :sentinel #'herdr-term--sentinel)))
      (process-put process 'herdr-term-buffer buffer)
      (setq herdr-term--process process)
      (herdr-term--update-mode-line)
      process)))

(defun herdr-term--kill-process ()
  "Delete this buffer's stream process without waking its sentinel.
Detaching the sentinel and filter first is what tells an intentional
teardown apart from herdr dropping the stream.  Left attached, the
sentinel would fire after teardown and race a spurious reconnect
against the one the caller is about to make."
  (when (process-live-p herdr-term--process)
    (set-process-sentinel herdr-term--process #'ignore)
    (set-process-filter herdr-term--process #'ignore)
    (delete-process herdr-term--process)))

(defun herdr-term--sentinel (process event)
  "Recover the stream of PROCESS after EVENT reported that it dropped.
An intentional teardown detaches this sentinel first, so reaching here
always means herdr closed the stream on us.  A pane herdr no longer has
is an ending rather than a drop and is not retried at all.  A stream
that had already synced is reconnected as a transient drop.  One that
exits without ever syncing is retried
`herdr-term-max-connect-attempts' times and then abandoned, because an
invalid pane never becomes valid."
  (let ((buffer (process-get process 'herdr-term-buffer)))
    (when (and (buffer-live-p buffer)
               (memq (process-status process) '(exit signal)))
      (with-current-buffer buffer
        (let ((detail (or herdr-term--close-reason (string-trim event))))
          (cond
            ((herdr-term--pane-gone-p detail)
             (herdr-term--end-for-good))
            (herdr-term--last-seq
             (herdr-term--reconnect (format "stream exited: %s" detail)))
            (t
             (setq herdr-term--fail-count (1+ herdr-term--fail-count))
             (if (herdr-term--gave-up-p)
                 (progn
                   (herdr-term--update-mode-line)
                   (message
                    "herdr-term[%s]: gave up after %d tries (%s); %s retries"
                    herdr-term--pane herdr-term--fail-count detail
                    (substitute-command-keys "\\[herdr-term-resync]")))
               (herdr-term--reconnect
                (format "connect failed: %s (attempt %d/%d)" detail
                        herdr-term--fail-count
                        herdr-term-max-connect-attempts))))))))))

(defconst herdr-term--pane-gone-regexp (rx (or "not found" "exited") eos)
  "Match a close reason that means the pane itself is gone.
As of herdr 0.7.5 four reasons end this way: a fresh connect that
cannot resolve the pane says \"terminal session ACTION failed: terminal
target PANE not found\", an attach that never lands or is taken away
says \"terminal attach failed\" or \"terminal attach ended: terminal ID
not found\", and a pane whose program finished says \"terminal ID
exited\" — which herdr sends only once the pane is off its own tree.
Every other reason herdr sends ends elsewhere, several of them in a
\"; retry\" this must not match.

Matched as text because nothing structured carries it — the reason
arrives as prose, and the alternative is a second question to the
server from inside a process sentinel, where a synchronous request
hangs Emacs.  Nothing in `Package-Requires' pins a herdr version, so
this docstring is the only record of the wording relied on: a reason
that gains a suffix stops matching here, and the retry loop this
prevents comes back.")

(defun herdr-term--pane-gone-p (detail)
  "Return non-nil when DETAIL is herdr reporting the pane as gone.
DETAIL is checked for being a string because it can come straight from
the wire, where the reason is whatever JSON herdr sent."
  (and (stringp detail)
       (string-match-p herdr-term--pane-gone-regexp detail)))

(defun herdr-term--end-for-good ()
  "End this buffer's stream for good, its pane having gone.
Retrying is pointless, so the stream, its bridge and every pending
timer go rather than being rescheduled.  What becomes of the buffer is
`herdr-term-pane-gone-action'.

Nothing is reported.  A pane that went is how a pane ordinarily ends,
and closing one workspace ends every pane in it at once, so a line each
would bury whatever the echo area was showing under a verdict the mode
line already carries and `herdr-term--close-reason' still explains.

A kill is deferred rather than run here, because `kill-buffer' runs
`kill-buffer-query-functions' and arbitrary hooks, and a process
sentinel — holding this buffer current — is no place for either."
  (herdr-term--teardown)
  (setq herdr-term--pane-gone t)
  (herdr-term--update-mode-line)
  (when (eq herdr-term-pane-gone-action 'kill)
    (run-at-time 0 nil #'kill-buffer (current-buffer))))

(defun herdr-term--gave-up-p ()
  "Return non-nil when this buffer stopped retrying its stream."
  (>= herdr-term--fail-count herdr-term-max-connect-attempts))

(defun herdr-term--reconnect (reason)
  "Reconnect this buffer's stream to obtain a fresh full frame.
REASON is reported to the user.  The dying stream is dropped at once,
so that no later frame of its own can reach the grid, but the restart
is rate limited to one per `herdr-term-reconnect-min-interval'.  A
restart that must wait is deferred rather than dropped, because the
caller is often a sentinel whose process is already gone: dropping it
would strand the buffer on a dead stream."
  (herdr-term--kill-process)
  (let* ((buffer (current-buffer))
         (since (and herdr-term--last-reconnect
                     (- (float-time) herdr-term--last-reconnect)))
         (wait (if since (- herdr-term-reconnect-min-interval since) 0)))
    (cond
      ((<= wait 0)
       (message "herdr-term[%s]: reconnecting (%s)" herdr-term--pane reason)
       (herdr-term--start-stream buffer))
      ((not (timerp herdr-term--reconnect-timer))
       (message "herdr-term[%s]: reconnecting in %.1fs (%s)"
                herdr-term--pane wait reason)
       (setq herdr-term--reconnect-timer
             (run-at-time wait nil #'herdr-term--reconnect-deferred
                          buffer))))))

(defun herdr-term--reconnect-deferred (buffer)
  "Run the reconnect that BUFFER deferred to stay inside the rate limit."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq herdr-term--reconnect-timer nil)
      (herdr-term--start-stream buffer))))

(defun herdr-term--cancel-reconnect ()
  "Cancel this buffer's deferred reconnect, if one is pending."
  (when (timerp herdr-term--reconnect-timer)
    (cancel-timer herdr-term--reconnect-timer))
  (setq herdr-term--reconnect-timer nil))

;;; Frame Application

(defun herdr-term--filter (process chunk)
  "Accumulate CHUNK from PROCESS and apply each complete message in it."
  (let ((buffer (process-get process 'herdr-term-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq herdr-term--stdout (concat herdr-term--stdout chunk))
        (let* ((parts (split-string herdr-term--stdout "\n"))
               (complete (butlast parts)))
          (setq herdr-term--stdout (car (last parts)))
          ;; A reconnect mid-chunk kills this stream, so the rest of
          ;; `complete' belongs to a dead one and must not reach the new
          ;; grid.
          (catch 'herdr-term--resynced
            (dolist (line complete)
              (unless (string-empty-p line)
                (let ((object
                       (ignore-errors
                         (json-parse-string line
                                            :false-object nil
                                            :null-object nil))))
                  (when (and (hash-table-p object)
                             (eq 'resync
                                 (herdr-term--apply-message buffer object)))
                    (throw 'herdr-term--resynced nil)))))))))))

(defun herdr-term--apply-message (buffer object)
  "Apply one decoded stream message OBJECT to BUFFER.
Return the symbol `resync' when the message triggered a reconnect, so
that the caller can stop feeding it the now stale remainder of the same
chunk."
  (with-current-buffer buffer
    (pcase (gethash "type" object)
      ("terminal.frame" (herdr-term--apply-frame object))
      ("terminal.closed" (herdr-term--note-closed object)))))

(defun herdr-term--apply-frame (object)
  "Apply frame OBJECT to the current buffer.
Return the symbol `resync' when the frame triggered a reconnect."
  (let ((seq (gethash "seq" object))
        (full (gethash "full" object))
        (rows (gethash "height" object))
        (cols (gethash "width" object))
        (payload (gethash "bytes" object)))
    (prog1
        (cond
          ((null payload)
           (herdr-term--reconnect "frame without bytes")
           'resync)
          (full
           (herdr-term--apply-full seq rows cols payload))
          ((null herdr-term--last-seq)
           (herdr-term--reconnect "delta before initial full frame")
           'resync)
          ((/= seq (1+ herdr-term--last-seq))
           (herdr-term--reconnect
            (format "seq gap %s->%s" herdr-term--last-seq seq))
           'resync)
          (t
           (herdr-term--apply-delta seq rows cols payload)))
      (herdr-term--update-mode-line))))

(defun herdr-term--apply-full (seq rows cols payload)
  "Reset the grid to ROWS by COLS and paint base64 PAYLOAD as frame SEQ.
Return the symbol `resync' when applying failed, having already asked
for a fresh stream: a full frame is authoritative, so a failure leaves
the grid in a state only a new connection can resolve."
  (condition-case err
      (progn
        (herdr-term--reset-term rows cols)
        (herdr-term--paint (base64-decode-string payload))
        (setq herdr-term--last-seq seq
              herdr-term--fail-count 0)
        ;; A fresh connection arrives at herdr's idea of the pane, which
        ;; is whatever its own client sized it to.  This is where the
        ;; window gets to disagree, and the only place the stream is
        ;; known to be up.
        (herdr-term-fit-to-window)
        nil)
    (error (herdr-term--reconnect (format "full apply failed: %S" err))
           'resync)))

(defun herdr-term--apply-delta (seq rows cols payload)
  "Paint base64 PAYLOAD as frame SEQ, resizing to ROWS by COLS first.
Return the symbol `resync' when applying failed.  A delta assumes the
grid the previous frame left behind, so a malformed one diverges
exactly as a dropped frame does and recovers the same way."
  (condition-case err
      (progn
        (herdr-term--maybe-resize rows cols)
        (herdr-term--paint (base64-decode-string payload))
        (setq herdr-term--last-seq seq)
        nil)
    (error (herdr-term--reconnect (format "delta apply failed: %S" err))
           'resync)))

(defun herdr-term--note-closed (object)
  "Record the `reason' carried by `terminal.closed' message OBJECT.
Recovery belongs to the process sentinel, which decides from this
reason whether the stream reconnects or the pane has ended, and reports
only the outcome.  A close is the beginning of that decision and not
news on its own, so nothing is said here.

`herdr-term--last-seq' is left intact in particular: clearing it would
strand a still live stream on \"delta before initial full frame\" for
every frame that follows."
  (setq herdr-term--close-reason (gethash "reason" object))
  nil)

(defun herdr-term--maybe-resize (rows cols)
  "Resize this buffer's grid to ROWS by COLS when they changed.
A frame's dimensions are authoritative: painting a repaint sized for a
different grid would place cells outside it."
  (when (and rows cols
             (or (not (eql rows herdr-term--rows))
                 (not (eql cols herdr-term--cols))))
    (ghostel--set-size-with-cell-dims ghostel--term
                                      (max 1 rows) (max 1 cols))
    (setq herdr-term--rows rows
          herdr-term--cols cols)))

(defun herdr-term--reset-term (rows cols)
  "Recreate this buffer's ghostel terminal at ROWS by COLS.
A full frame is authoritative, so it must land on a grid as clean as
the one a new buffer gets.  Painting it onto a reused grid resets
neither the scroll region, nor the saved cursor, nor an alternate
screen save left behind by an application herdr flattened away, so a
grid that had drifted from herdr's would stay wrong.  Recreating it
guarantees parity."
  (let ((rows (max 1 (or rows herdr-term--rows 24)))
        (cols (max 1 (or cols herdr-term--cols 80))))
    (herdr-term--return-to-semi-char)
    ;; `ghostel--init-buffer' refuses to run while `ghostel--process' holds
    ;; a live process, and on a writable buffer that slot is where the input
    ;; bridge lives.  Shadow the slot rather than retiring the bridge, whose
    ;; unflushed bytes are keystrokes the user already typed.
    (let ((ghostel--process nil))
      (ghostel--init-buffer (current-buffer) rows cols))
    ;; ghostel keeps `ghostel--adjust-size' on the buffer-local hook, and it
    ;; acts whenever `ghostel--process' is live, which the input bridge makes
    ;; true.  It would resize the grid to the Emacs window while herdr went
    ;; on sending frames sized for its own, a divergence no `seq' gap marks.
    (remove-hook 'window-size-change-functions #'ghostel--adjust-size t)
    (setq herdr-term--rows rows
          herdr-term--cols cols)
    (when herdr-term--writable
      (herdr-term--ensure-input-bridge))))

(defun herdr-term--return-to-semi-char ()
  "Leave whichever input mode the buffer is in, ahead of a grid rebuild.
Rebuilding sets `ghostel--input-mode' to `semi-char' but runs no
teardown, so a copy, Emacs, char or line mode leaves its keymap, its
read-only barrier and its cursor style behind.  The buffer then claims
to take terminal input while its keys still run the old map, and it
stays that way: `ghostel-semi-char-mode' returns early on the variable
that already reads `semi-char'.  Switching first is what keeps the two
in step."
  (unless (eq ghostel--input-mode 'semi-char)
    (ghostel-semi-char-mode)))

(defun herdr-term--paint (bytes)
  "Feed BYTES to this buffer's ghostel terminal and repaint it.
The repaint is forced because herdr wraps frames in synchronized output
\(mode 2026), under which a deferred redraw would leave the buffer one
frame behind."
  (ghostel--write-vt ghostel--term bytes)
  (ghostel--redraw-now (current-buffer) t))

;;; Scrolling

(defun herdr-term--page-lines ()
  "Return how many lines make a screenful of this pane.
Two rows are kept so that a page of scrolling overlaps its neighbour,
which is what makes a long read followable."
  (max 1 (- (or herdr-term--rows 24) 2)))

(defun herdr-term--scroll (direction lines)
  "Scroll this buffer's pane LINES lines in DIRECTION.
DIRECTION is the string \"up\" or \"down\".

Where the pane is scrolled to is a property of the pane and not of this
buffer, so the herdr TUI and every other client showing it scroll too.
herdr keeps no per-client viewport, which is also why an observing
buffer cannot scroll at all: `terminal.scroll' is a control command,
and only one client at a time holds control of a pane."
  (unless herdr-term--writable
    (user-error "Buffer only observes %s; %s takes control of it"
                herdr-term--pane
                (substitute-command-keys "\\[herdr-term-take-control]")))
  (unless (process-live-p herdr-term--process)
    (user-error "No live stream for %s" herdr-term--pane))
  (when (> lines 0)
    (herdr-term--send-command
     (list :type "terminal.scroll"
           :direction direction
           :lines (min lines herdr-term--scroll-limit)
           ;; `wheel' moves the pane's viewport over its scrollback.
           ;; `page_key' would instead deliver PageUp or PageDown to the
           ;; program as input, which the input bridge already does for
           ;; the unshifted keys.
           :source "wheel"))))

;;; Fitting the Pane to its Window

;; herdr owns the grid, so the window cannot simply resize it locally: the
;; frames still arriving are sized for herdr's own idea of the pane, and a
;; grid that disagrees renders them in the wrong places.  The window asks
;; herdr to change size instead, and the frames that come back bring the
;; new dimensions with them.

(defun herdr-term--note-resize (window)
  "Fit the herdr pane displayed by WINDOW to WINDOW.
`window-size-change-functions' hands a buffer-local entry the window
that changed, where a global one is handed the frame, and this is
registered buffer-locally.  Read as a frame, the window reached
`window-list' as its FRAME argument and signalled \"Window is on a
different frame\" — every resize errored and nothing was ever fitted.

Resolved from WINDOW rather than from the current buffer, because
redisplay runs this with an arbitrary buffer current."
  (let ((buffer (window-buffer window)))
    (when (buffer-local-value 'herdr-term--pane buffer)
      (with-current-buffer buffer
        (herdr-term--schedule-resize window)))))

(defun herdr-term-fit-to-window ()
  "Schedule a resize when this buffer's window and its grid disagree."
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (herdr-term--schedule-resize window)))

(defun herdr-term--schedule-resize (window)
  "Ask herdr to fit this buffer's pane to WINDOW, once it settles."
  (let ((rows (max 1 (window-body-height window)))
        (cols (max 1 (window-body-width window))))
    (unless (or (and (eql rows herdr-term--rows) (eql cols herdr-term--cols))
                (timerp herdr-term--resize-timer))
      (setq herdr-term--resize-timer
            (run-at-time herdr-term-resize-delay nil
                         #'herdr-term--resize-now (current-buffer))))))

(defun herdr-term--resize-now (buffer)
  "Fit BUFFER's pane to the window showing it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq herdr-term--resize-timer nil)
      (when-let* ((window (get-buffer-window buffer t))
                  (rows (max 1 (window-body-height window)))
                  (cols (max 1 (window-body-width window)))
                  ((not (and (eql rows herdr-term--rows)
                             (eql cols herdr-term--cols)))))
        (if (and herdr-term--writable
                 (process-live-p herdr-term--process))
            (herdr-term--send-command
             (list :type "terminal.resize" :cols cols :rows rows))
          ;; An observer holds no control of the pane and so cannot ask
          ;; for a size.  A fresh connection can, because it names one,
          ;; and the reconnect is what makes an observed pane fit at all.
          (setq herdr-term--rows rows
                herdr-term--cols cols)
          (herdr-term--reconnect "window resized"))))))

(defun herdr-term--cancel-resize ()
  "Cancel this buffer's pending resize, if there is one."
  (when (timerp herdr-term--resize-timer)
    (cancel-timer herdr-term--resize-timer))
  (setq herdr-term--resize-timer nil))

;;; Input

(defun herdr-term--input-target (process)
  "Return the herdr terminal buffer PROCESS accepts input for, or nil.
Only an input bridge carries `herdr-term-input-buffer', so every other
process in the session reads as nil and is left to its own sink.  The
control stream carries `herdr-term-buffer' instead, and the two tags
must stay distinct: were the stream to answer here, the write
`herdr-term--send-input' makes would divert into itself."
  (and (processp process)
       (let ((buffer (process-get process 'herdr-term-input-buffer)))
         (and (buffer-live-p buffer) buffer))))

(defun herdr-term--divert-input (send process string)
  "Send STRING to herdr directly when PROCESS is an input bridge.
Otherwise hand PROCESS and STRING to SEND, the advised
`process-send-string'.

Diverting is what keeps a keystroke inside the command that read it.
Left to the bridge, the bytes travel down a pipe and come back through a
process filter, and Emacs runs that filter only once its event loop
notices the descriptor.  That wait costs a fraction of a millisecond
under X11 and around twelve under the Cocoa event loop, on every
keystroke.  The bridge stays live because ghostel requires a process in
`ghostel--process', and because it still carries any write that reaches
the pipe by a path this advice does not see.

A device report the terminal raises mid-repaint reaches here too, from
inside the send that is painting.  Emacs queues writes per process and
drains them in order, so the nested line follows the outer one whole
rather than splitting it.

Errors are demoted because ghostel discards any signal but `quit' that
crosses back into its module, so a raised one would lose the keystroke
without a word."
  (if-let* ((buffer (herdr-term--input-target process)))
      (with-current-buffer buffer
        (with-demoted-errors "herdr-term: input dropped: %S"
          (herdr-term--send-input string)))
    (funcall send process string)))

(defun herdr-term--ensure-input-bridge ()
  "Point `ghostel--process' at a live bridge to the control stream.
ghostel drives input the way any terminal does: its handlers and its
module key encoder write bytes to the terminal's PTY, which with no
native process is whatever `ghostel--process' holds.  Setting that to a
`cat' process is what makes every input path work alike, including the
encoder paths for backspace, arrows and function keys that write inside
the module and so cannot be reached by rebinding a key.

Those module writes are ordinary `process-send-string' calls, so
`herdr-term--divert-input' forwards them without the round trip through
the bridge.  The bridge is what makes the paths uniform; the advice is
what makes them prompt.  The advice outlives any one buffer and is
retired by `herdr-term--kill-input-bridge' with the last bridge.

The tag and the advice go on together on every call, rather than only
when this makes the bridge.  A bridge that predates the advice cannot
tag itself, and reloading the library over a running session leaves one
of exactly that kind: input still works, by the slow path, and nothing
says why.

This is idempotent, and must run after every `ghostel--init-buffer',
which resets `ghostel--process' to nil."
  (unless (process-live-p herdr-term--input-bridge)
    (let ((buffer (current-buffer)))
      (setq herdr-term--input-bridge
            (make-process
             :name (format "herdr-term-input:%s" herdr-term--pane)
             :buffer nil
             :command '("cat")
             :connection-type 'pipe
             :coding 'binary
             :noquery t
             :filter (lambda (_process bytes)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (herdr-term--send-input bytes))))))))
  (process-put herdr-term--input-bridge 'herdr-term-input-buffer
               (current-buffer))
  (advice-add 'process-send-string :around #'herdr-term--divert-input)
  (setq ghostel--process herdr-term--input-bridge))

(defun herdr-term--input-bridge-live-p ()
  "Return non-nil while a live input bridge remains in any buffer."
  (seq-some (lambda (buffer)
              (process-live-p
               (buffer-local-value 'herdr-term--input-bridge buffer)))
            (buffer-list)))

(defun herdr-term--kill-input-bridge ()
  "Delete this buffer's input bridge, releasing `ghostel--process'.
Retire the divert with the last bridge in the session, so that an Emacs
that is done with herdr stops filtering every `process-send-string' it
makes."
  (when (process-live-p herdr-term--input-bridge)
    (delete-process herdr-term--input-bridge))
  (setq herdr-term--input-bridge nil
        ghostel--process nil)
  (unless (herdr-term--input-bridge-live-p)
    (advice-remove 'process-send-string #'herdr-term--divert-input)))

(defun herdr-term--send-command (command)
  "Write COMMAND, a plist, to the control stream as one JSON line."
  (process-send-string herdr-term--process
                       (concat (json-serialize command) "\n")))

(defun herdr-term--send-input (bytes)
  "Forward raw terminal input BYTES to the stream as `terminal.input'."
  (when (and herdr-term--writable
             (process-live-p herdr-term--process))
    (let ((unibyte (if (multibyte-string-p bytes)
                       (encode-coding-string bytes 'utf-8)
                     bytes)))
      (herdr-term--send-command
       (list :type "terminal.input"
             :bytes (base64-encode-string unibyte t))))))

;;; Presentation

(defun herdr-term--update-mode-line ()
  "Refresh `mode-line-process' from this buffer's stream state."
  (setq mode-line-process
        (format " herdr:%s[%s%s]"
                herdr-term--pane
                (if herdr-term--writable "rw" "ro")
                (cond
                  (herdr-term--pane-gone " closed")
                  ((herdr-term--gave-up-p) " dead")
                  (herdr-term--last-seq
                   (format " %d" herdr-term--last-seq))
                  (t " …"))))
  (force-mode-line-update))

;;; Panes

(defun herdr-term--panes ()
  "Return an alist of (PANE-ID . INFO) for every live herdr pane.
INFO is the hash-table herdr reported for that pane."
  (let ((panes (gethash "panes" (herdr-api-request "pane.list"))))
    (seq-map (lambda (pane) (cons (gethash "pane_id" pane) pane))
             (or panes []))))

(defun herdr-term-read-pane (prompt)
  "Read the identifier of a live herdr pane, prompting with PROMPT.
Candidates are annotated with the pane's working directory, its
detected agent and its workspace."
  (let ((panes (herdr-term--panes)))
    ;; A session with no panes is an ordinary state herdr reports happily,
    ;; not a failure of the call, so say what to do about it.
    (unless panes
      (user-error "No live herdr panes; create one with %s"
                  (substitute-command-keys "\\[herdr-term-new]")))
    (let* ((annotate
            (lambda (id)
              (when-let* ((pane (cdr (assoc id panes))))
                (let ((cwd (gethash "cwd" pane))
                      (agent (gethash "agent" pane))
                      (workspace (gethash "workspace_id" pane)))
                  (concat "  " (or cwd "")
                          (if agent (format " (%s)" agent) "")
                          (if workspace (format " [%s]" workspace) ""))))))
           (completion-extra-properties
            (list :annotation-function annotate)))
      (completing-read prompt (mapcar #'car panes) nil t))))

;;; _
(provide 'herdr-term)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-term.el ends here
