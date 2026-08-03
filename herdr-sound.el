;;; herdr-sound.el --- Sound when an agent wants you  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>

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

;; A sound when an agent starts waiting for you, and another when one
;; finishes work you were not watching.  Turn it on with
;; `herdr-sound-mode'.

;; The division of labour is herdr's.  Its headless server decides that a
;; state changed and forwards a notification, and each connected client
;; makes the noise; the server plays nothing itself.  This is that client
;; half for Emacs.

;; An agent becoming blocked asks for attention, always — herdr never
;; suppresses that one.  Finishing is subtler, because herdr has already
;; decided whether it is worth announcing before the status reaches us.
;; "done" and "idle" are one internal state, split by whether the operator
;; is taken to have seen the work end: herdr writes `seen' from its own
;; suppression rule and reports the unseen half as "done".  So "done" is
;; the finish herdr wants announced, and "idle" is the one it has already
;; discounted.  Deriving that here from working-to-idle would announce
;; finishes herdr deliberately silenced.

;; Where this departs from herdr is the second guess: a finish is dropped
;; when the pane is on screen in Emacs.  herdr asks the same question of
;; its own active tab, and the two can disagree, so a finish suppressed
;; there and not here is heard.  That is the intent — the question worth
;; asking from Emacs is whether you can see the pane from Emacs.

;; The transitions are read out of the session tree rather than off the
;; wire.  herdr does have a `pane.agent_status_changed' event, but it is
;; subscribed one pane at a time, and this needs every pane; `pane.updated'
;; already reports the same change for all of them, and
;; `herdr-session-change-hook' already fires on it.

;; What gets played is not herdr's.  Its two sounds are mp3 files compiled
;; into its binary, with no copy on disk to point at, and Emacs plays wav
;; and au only.  So the default here is the bell.  Name a file in
;; `herdr-sound-request-file' and it goes to an external player instead,
;; chosen from the same list herdr chooses from.

;;; Code:

(require 'seq)

(require 'herdr-session)

;;; Options

(defgroup herdr-sound nil
  "Sound when a herdr agent wants your attention."
  :group 'herdr
  :prefix "herdr-sound-")

(defcustom herdr-sound-enabled t
  "Whether a sound is made for a change that would otherwise make one.
This is not `herdr-sound-mode', which is what follows the session at
all.  Turning this off leaves the mode running and still watching, so
that turning it back on announces what happens next rather than a
backlog of what it missed.  Turn the mode off to stop watching."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-sound
  :type 'boolean)

(defcustom herdr-sound-request-file nil
  "Sound file for an agent that started waiting, or nil for the bell.
A file is handed to the first of `herdr-sound-players' that is
installed, so it may be in any format that player reads.  Nil rings the
bell, because Emacs plays only wav and au and herdr's own sounds are
neither."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-sound
  :type '(choice (const :tag "Ring the bell" nil) file))

(defcustom herdr-sound-done-file nil
  "Sound file for an agent that finished, or nil for the bell.
See `herdr-sound-request-file'."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-sound
  :type '(choice (const :tag "Ring the bell" nil) file))

(defcustom herdr-sound-players
  '(("paplay")
    ("pw-play")
    ("ffplay" "-nodisp" "-autoexit" "-loglevel" "quiet")
    ("mpg123" "-q")
    ("mpv" "--no-video" "--really-quiet"))
  "Players tried in turn, each as (PROGRAM ARGUMENT...).
The first one installed is run with the sound file as its last
argument.  This is herdr's list in herdr's order, and bare aplay is
absent from it for herdr's reason: it does not decode mp3, so handed
one it plays the bytes as raw PCM."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-sound
  :type '(repeat (cons string (repeat string))))

(defcustom herdr-sound-agents '(("droid" . off))
  "What each kind of agent is allowed to sound, by herdr's name for it.
An entry is (KIND . SETTING), where SETTING is `off' to silence that
kind, or `on' or `default' to leave it heard.  A kind with no entry is
heard.  droid is off here because it is off in herdr, which ships it
that way for being noisy."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-sound
  :type '(alist :key-type string
                :value-type (choice (const :tag "Silence this kind" off)
                                    (const :tag "Heard, said so" on)
                                    (const :tag "Heard" default))))

;;; Variables

(defvar herdr-sound--statuses (make-hash-table :test #'equal)
  "The status each pane was last seen in, keyed by pane id.
A pane absent from this has never been seen, and its first status is
not a transition — without that, every agent already waiting would
sound at once the moment Emacs connected.")

;; Declared rather than required, as the panels do: this must stay usable
;; without the terminal, whose ghostel dependency loads a native module.
(defvar herdr-term--pane)

;;; Mode

;;;###autoload
(define-minor-mode herdr-sound-mode
  "Make a sound when a herdr agent wants your attention.
An agent that starts waiting sounds `herdr-sound-request-file', and one
that finishes work you were not watching sounds
`herdr-sound-done-file'.  Which agents are heard is
`herdr-sound-agents'."
  :global t
  :group 'herdr-sound
  (if herdr-sound-mode
      (progn
        ;; Forgotten on the way in, so that turning the mode on is not
        ;; taken for every agent moving at once.
        (clrhash herdr-sound--statuses)
        (add-hook 'herdr-session-change-hook #'herdr-sound--note-change))
    (remove-hook 'herdr-session-change-hook #'herdr-sound--note-change)))

;;; Reading the Session

(defun herdr-sound--note-change ()
  "Sound out the agents whose status moved since the last look.
Every pane is looked at on each change, because the tree is re-read
whole and no event says which agent it was.

Each sound is played at most once however many agents moved together.
The tree is re-read on a timer and after a burst of events, so changes
herdr saw one at a time arrive here in one batch, and one bell per
batch is as much as anybody can tell apart."
  (let ((statuses (make-hash-table :test #'equal))
        (sounds nil))
    (dolist (agent (herdr-session-agents))
      (let* ((pane (gethash "pane_id" agent))
             (status (gethash "agent_status" agent))
             (previous (gethash pane herdr-sound--statuses))
             (sound (and previous (herdr-sound--transition previous status))))
        (puthash pane status statuses)
        (when (and sound
                   (not (memq sound sounds))
                   herdr-sound-enabled
                   (herdr-sound--heard-p (gethash "agent" agent))
                   (or (eq sound 'request)
                       (not (herdr-sound--watched-p pane))))
          (push sound sounds))))
    (setq herdr-sound--statuses statuses)
    (mapc #'herdr-sound--play (nreverse sounds))))

(defun herdr-sound--transition (previous status)
  "Return the sound for a move from PREVIOUS to STATUS, or nil.
Becoming blocked asks for attention.  Reaching \"done\" reports work
that finished, and reaching \"idle\" reports nothing: the two are one
state on herdr's side, split by whether it holds the operator to have
watched the work end, and \"idle\" is the half it has already decided
against announcing."
  (cond
    ((equal previous status) nil)
    ((equal status "blocked") 'request)
    ((equal status "done") 'done)))

(defun herdr-sound--heard-p (kind)
  "Return non-nil when an agent of KIND is allowed to sound."
  (not (eq (cdr (assoc kind herdr-sound-agents)) 'off)))

(defun herdr-sound--watched-p (pane)
  "Return non-nil when PANE is shown by a window on a visible frame.
Visible, rather than any frame at all: a pane on an iconified frame or
one on another desktop is not being watched, and taking it for watched
drops the sound that says the work is done.

Nil when the terminal has never been loaded, which is right rather
than merely safe — with no terminal there are no panes on screen to
be watching."
  (and (boundp 'herdr-term--pane)
       (seq-some (lambda (buffer)
                   (and (equal (buffer-local-value 'herdr-term--pane buffer)
                               pane)
                        (get-buffer-window buffer 'visible)))
                 (buffer-list))))

;;; Playing

(defun herdr-sound--play (sound)
  "Play SOUND, which is `request' or `done'.
The player runs detached and its output is dropped, so a sound that
takes a second to play does not hold Emacs up for it.  The bell is the
answer both when no file is named and when nothing is installed to play
one, because a notification nobody hears is worse than a plain beep."
  (if-let* ((file (herdr-sound--file sound))
            (player (seq-find (lambda (player)
                                (executable-find (car player)))
                              herdr-sound-players)))
      (apply #'start-process "herdr-sound" nil
             (car player) (append (cdr player) (list file)))
    (ding)))

(defun herdr-sound--file (sound)
  "Return the file named for SOUND, or nil when none is."
  (pcase sound
    ('request herdr-sound-request-file)
    ('done herdr-sound-done-file)))

;;; _
(provide 'herdr-sound)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-sound.el ends here
