;;; herdr-sound-tests.el --- Tests for herdr-sound  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

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

;; Which changes in the session tree make a sound, and which do not.  The
;; tree is fed from hand-written snapshots through the fixture in
;; herdr-session-tests; playback itself is replaced by a recorder, so
;; nothing here needs an audio device or a player on PATH.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-sound)
(require 'herdr-session-tests)

;; Required outright, not left to whichever suite happens to load first.
;; `herdr-sound--watched-p' answers nil for every pane until the terminal
;; defines the variable it reads, so a suite that did not load it would
;; find the suppression tests passing over a function that never ran.
(require 'herdr-term)

(defvar herdr-sound-test-played nil
  "One sound symbol per call, most recent first.")

(defmacro herdr-sound-with-recorder (&rest body)
  "Evaluate BODY with playback recorded rather than heard.
Each pane's last seen status is forgotten first, so a test starts with
a tree it has never seen before."
  (declare (indent 0) (debug t))
  `(let ((herdr-sound-test-played nil)
         (herdr-sound-enabled t)
         (herdr-sound--statuses (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'herdr-sound--play)
                (lambda (sound) (push sound herdr-sound-test-played))))
       ,@body)))

(defun herdr-sound-test-snapshot (&rest agents)
  "Return a session snapshot holding AGENTS.
Each of AGENTS is a (PANE-ID KIND STATUS) list."
  (list :agents
        (vconcat
         (mapcar (pcase-lambda (`(,pane ,kind ,status))
                   (list :pane_id pane :agent kind :agent_status status))
                 agents))))

(defmacro herdr-sound-with-tree (agents &rest body)
  "Evaluate BODY with the session tree holding AGENTS, then note it.
AGENTS is a list of (PANE-ID KIND STATUS)."
  (declare (indent 1) (debug t))
  `(herdr-session-with-snapshot (apply #'herdr-sound-test-snapshot ,agents)
     ,@body))

(defun herdr-sound-test-observe (agents)
  "Set the session tree to AGENTS and let herdr-sound look at it."
  (herdr-sound-with-tree agents
    (herdr-sound--note-change)))

;;; What Makes a Sound

(ert-deftest herdr-sound--note-change:asks-for-attention-when-blocked ()
  "An agent that starts waiting is the whole point of this."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
    (should (equal herdr-sound-test-played '(request)))))

(ert-deftest herdr-sound--note-change:says-nothing-about-a-pane-it-has-not-seen ()
  "The first look at the tree is not a transition.
Treated as one, every agent already waiting would sound at once, which
is what starting Emacs looks like."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")
                                ("w1:p2" "codex" "working")))
    (should (null herdr-sound-test-played))))

(ert-deftest herdr-sound--note-change:says-nothing-when-nothing-moved ()
  "The tree is re-read on every change to any part of it."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
    (should (equal herdr-sound-test-played '(request)))))

(ert-deftest herdr-sound--note-change:reports-work-that-finished ()
  "Reaching done is work finishing, which herdr wants announced."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "done")))
    (should (equal herdr-sound-test-played '(done)))))

(ert-deftest herdr-sound--note-change:says-nothing-about-idle ()
  "Idle is the finish herdr has already decided against announcing.
On its side idle and done are one state told apart by a `seen' flag,
which it writes from its own suppression rule.  Reading working-to-idle
as a finish would sound exactly the ones it chose to silence."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "idle")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "unknown")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "idle")))
    (should (null herdr-sound-test-played))))

(ert-deftest herdr-sound--note-change:sounds-once-for-a-burst ()
  "Changes herdr saw one at a time arrive here in one batch.
One bell per batch is as much as anybody can tell apart, and twenty
agents unblocking at once would otherwise start twenty players."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")
                                ("w1:p2" "codex" "working")
                                ("w1:p3" "gemini" "working")))
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")
                                ("w1:p2" "codex" "blocked")
                                ("w1:p3" "gemini" "done")))
    (should (equal (sort (copy-sequence herdr-sound-test-played)
                         #'string<)
                   '(done request)))))

;;; Who is Looking

(ert-deftest herdr-sound--note-change:keeps-quiet-about-a-pane-you-are-watching ()
  "Work finishing in front of you needs no sound; you saw it.
This is herdr's own rule, which suppresses `done' for the active tab."
  (herdr-sound-with-recorder
    (let ((buffer (generate-new-buffer "*herdr:w1:p1*")))
      (unwind-protect
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (with-current-buffer buffer (setq-local herdr-term--pane "w1:p1"))
            (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
            (herdr-sound-test-observe '(("w1:p1" "claude" "done")))
            (should (null herdr-sound-test-played)))
        (kill-buffer buffer)))))

(ert-deftest herdr-sound--note-change:still-asks-for-attention-in-view ()
  "Waiting is not the same as finishing.
herdr never suppresses `request': an agent asking a question wants an
answer whether or not its pane happens to be on screen."
  (herdr-sound-with-recorder
    (let ((buffer (generate-new-buffer "*herdr:w1:p1*")))
      (unwind-protect
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (with-current-buffer buffer (setq-local herdr-term--pane "w1:p1"))
            (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
            (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
            (should (equal herdr-sound-test-played '(request))))
        (kill-buffer buffer)))))

(ert-deftest herdr-sound--watched-p:asks-only-about-visible-frames ()
  "An iconified frame is not one you are watching a pane on.
`get-buffer-window' takes t for every frame there is, including
invisible and iconified ones, so a pane on a minimised frame would
count as watched and the sound saying the work is done would be
dropped.  The argument is asserted rather than the behaviour because
batch Emacs has no second frame to make invisible."
  (let ((buffer (generate-new-buffer "*herdr:w1:p1*"))
        (frames nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq-local herdr-term--pane "w1:p1"))
          (cl-letf (((symbol-function 'get-buffer-window)
                     (lambda (_buffer &optional all-frames)
                       (push all-frames frames)
                       nil)))
            (herdr-sound--watched-p "w1:p1"))
          (should (equal frames '(visible))))
      (kill-buffer buffer))))

;;; Which Agents

(ert-deftest herdr-sound--note-change:obeys-an-agent-turned-off ()
  "One kind of agent can be silenced, as herdr can silence one."
  (herdr-sound-with-recorder
    (let ((herdr-sound-agents '(("claude" . off))))
      (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
      (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
      (should (null herdr-sound-test-played)))))

(ert-deftest herdr-sound--note-change:hears-a-kind-said-to-be-heard ()
  "Three values are settable and only one of them silences."
  (herdr-sound-with-recorder
    (let ((herdr-sound-agents '(("claude" . on) ("codex" . default))))
      (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
      (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
      (should (equal herdr-sound-test-played '(request)))))
  (herdr-sound-with-recorder
    (let ((herdr-sound-agents '(("codex" . default))))
      (herdr-sound-test-observe '(("w1:p1" "codex" "working")))
      (herdr-sound-test-observe '(("w1:p1" "codex" "blocked")))
      (should (equal herdr-sound-test-played '(request))))))

(ert-deftest herdr-sound--note-change:silences-droid-by-default ()
  "Which is the one kind herdr itself ships turned off."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "droid" "working")
                                ("w1:p2" "claude" "working")))
    (herdr-sound-test-observe '(("w1:p1" "droid" "blocked")
                                ("w1:p2" "claude" "blocked")))
    (should (equal herdr-sound-test-played '(request)))))

(ert-deftest herdr-sound--note-change:says-nothing-at-all-when-disabled ()
  "One switch over everything, as herdr's `ui.sound.enabled' is."
  (herdr-sound-with-recorder
    (let ((herdr-sound-enabled nil))
      (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
      (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
      (should (null herdr-sound-test-played)))))

;;; Panes That Go Away

(ert-deftest herdr-sound--note-change:forgets-a-pane-that-closed ()
  "A pane id is handed out again, and the table would grow forever.
Forgetting also means a new pane in an old id is a first sighting
rather than a transition out of whatever the last one was doing."
  (herdr-sound-with-recorder
    (herdr-sound-test-observe '(("w1:p1" "claude" "working")))
    (herdr-sound-test-observe '())
    (should (zerop (hash-table-count herdr-sound--statuses)))
    (herdr-sound-test-observe '(("w1:p1" "claude" "blocked")))
    (should (null herdr-sound-test-played))))

;;; How It Is Played

(ert-deftest herdr-sound--play:rings-the-bell-with-no-file ()
  "The bell is what there is until a file is named.
Emacs plays wav and au only, and herdr's own sounds are mp3 built into
its binary, so nothing on disk exists to point at."
  (let ((herdr-sound-request-file nil)
        (rang nil))
    (cl-letf (((symbol-function 'ding) (lambda (&rest _) (setq rang t))))
      (herdr-sound--play 'request))
    (should rang)))

(ert-deftest herdr-sound--play:hands-a-file-to-the-first-player-there-is ()
  "The players are herdr's own list, tried in herdr's own order.
Two are installed, so the answer says which was preferred rather than
only that something was found."
  (let ((herdr-sound-request-file "/tmp/request.mp3")
        (herdr-sound-players '(("mpg123" "-q")
                               ("mpv" "--no-video")))
        (started nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program) (member program '("mpg123" "mpv"))))
              ((symbol-function 'start-process)
               (lambda (_name _buffer program &rest args)
                 (setq started (cons program args)))))
      (herdr-sound--play 'request))
    (should (equal started '("mpg123" "-q" "/tmp/request.mp3")))))

(ert-deftest herdr-sound--play:rings-the-bell-with-nothing-to-play-it ()
  "A named file and no player is still better heard than not at all."
  (let ((herdr-sound-done-file "/tmp/done.mp3")
        (rang nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'ding) (lambda (&rest _) (setq rang t))))
      (herdr-sound--play 'done))
    (should rang)))

(ert-deftest herdr-sound--file:tells-the-two-sounds-apart ()
  "Each transition has a file of its own to name."
  (let ((herdr-sound-request-file "/tmp/request.mp3")
        (herdr-sound-done-file "/tmp/done.mp3"))
    (should (equal (herdr-sound--file 'request) "/tmp/request.mp3"))
    (should (equal (herdr-sound--file 'done) "/tmp/done.mp3"))))

;;; Turning It On

(ert-deftest herdr-sound-mode:follows-the-session-only-while-on ()
  "The mode is what watches; `herdr-sound-enabled' only silences."
  (let ((herdr-session-change-hook nil))
    (herdr-sound-mode 1)
    (should (memq #'herdr-sound--note-change herdr-session-change-hook))
    (herdr-sound-mode -1)
    (should-not (memq #'herdr-sound--note-change herdr-session-change-hook))))

(ert-deftest herdr-sound-mode:forgets-what-it-saw-before-it-was-off ()
  "Turning it on is not every agent moving at once.
Statuses go stale while the mode is off, and read as transitions they
would announce a backlog nobody can act on."
  (let ((herdr-session-change-hook nil)
        (herdr-sound--statuses (make-hash-table :test #'equal)))
    (puthash "w1:p1" "working" herdr-sound--statuses)
    (herdr-sound-mode 1)
    (should (zerop (hash-table-count herdr-sound--statuses)))
    (herdr-sound-mode -1)))

(ert-deftest herdr-sound-players:never-offers-bare-aplay ()
  "Bare aplay is not among the players, as it is not among herdr's.
It does not decode mp3, so handed one it plays the bytes as raw PCM,
which is loud noise rather than a notification."
  (should-not (assoc "aplay" herdr-sound-players)))

;;; _
(provide 'herdr-sound-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-sound-tests.el ends here
