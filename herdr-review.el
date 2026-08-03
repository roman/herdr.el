;;; herdr-review.el --- The herdr reviews panel  -*- lexical-binding:t -*-

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

;; A panel of the code reviews waiting for you, and the commands that
;; start and end one.  A review is a review tool running in a tab of its
;; own, inside the workspace whose code is under review.

;; herdr has no concept of a code review, and needs none.  The review
;; reports itself over the socket as an agent, so herdr rolls its state up
;; to the tab and the workspace exactly as it does for a coding agent, and
;; every herdr client sees a blocked review without being taught anything.
;; This file reads it back out of the session tree the same way.

;; Which tool draws the review is not this file's business.  Starting and
;; ending one is the `herdr-review' script's, which a coding agent runs
;; when it wants a change looked at, and which a shell runs by hand; this
;; file is a third caller of it rather than a second implementation.
;; Today that script runs tuicr.

;; A workspace holds one review at a time.  Two reviews of one checkout
;; is more than an operator can hold at once, so asking for a second goes
;; to the first.

;; This file is not loaded with the rest of herdr.  It needs a tool herdr
;; does not, so `require' it yourself; doing so is what puts the Reviews
;; panel in the column and takes review rows out of the agents panel, so
;; that a review appears in one place.

;;; Code:

(require 'magit-section)
(require 'seq)

(require 'herdr-agents)
(require 'herdr-panel)
(require 'herdr-session)

;;; Options

(defgroup herdr-review nil
  "The code reviews waiting for you in a herdr session."
  :group 'herdr-panel
  :link '(url-link "https://github.com/roman/herdr.el"))

(defcustom herdr-review-program "herdr-review"
  "The script that starts and ends a review.
Named rather than reimplemented so that a review begun from Emacs, from
a shell, or by a coding agent is the same review, and so that which
review tool actually runs is that script's business rather than this
file's.  It ships apart from herdr, in the herdr-review project; put its
full path here when that project's `bin' directory is not on the
variable `exec-path'."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-review
  :type 'string)

(defconst herdr-review-agent "review"
  "The kind of agent a review reports itself as.
This is what tells a review apart from a coding agent in everything
herdr reports.  Not an option, because the same string is written by
the `herdr-review-program' script and read here: one of the two would
always be free to disagree with the other.  It names the work rather
than the tool doing it, so swapping that tool changes nothing here.")

(defcustom herdr-review-buffer-name "*herdr-reviews*"
  "Name of the buffer showing the reviews panel.
One buffer holds the list, as the spaces and agents panels do, and the
list has a row per workspace under review.  Reviews themselves are not
limited to one: every workspace may have its own, open at the same
time, each in its own tab and its own terminal buffer.  The limit is
one review per workspace, and it is the herdr-review script's."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-review
  :type 'string)

(defcustom herdr-review-border t
  "Whether to rule the reviews panel off from the panel above it.
The panels share a column with no mode line between them, so without a
rule they read as one list under several headings."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-review
  :type 'boolean)

(defcustom herdr-review-icon "⌥"
  "Glyph shown beside a review, in place of the agent kind."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-review
  :type 'string)

;;; Faces

(defface herdr-review-icon
  '((((background dark)) :foreground "#7aa2f7")
    (((background light)) :foreground "#2f5fbf")
    (t :inherit font-lock-keyword-face))
  "Face for the mark beside a review."
  :group 'herdr-review)

;;; Keymaps

(defvar-keymap herdr-review-mode-map
  :doc "Keymap for `herdr-review-mode'."
  :parent herdr-panel-mode-map
  "+" #'herdr-review-open
  "-" #'herdr-review-close)

(with-eval-after-load 'evil
  (herdr-panel-install-evil-keys herdr-review-mode-map))

;;; Mode

(define-derived-mode herdr-review-mode magit-section-mode "Herdr Reviews"
  "Major mode for the herdr reviews panel."
  :interactive nil
  (herdr-panel-init #'herdr-review-refresh #'herdr-review--pane-at-point))

;;; Commands

;;;###autoload
(defun herdr-review ()
  "Show the panel listing the reviews waiting to be read."
  (interactive)
  (pop-to-buffer (herdr-review-panel)))

(defun herdr-review-panel ()
  "Return the reviews buffer, drawn and tracking the session.
Separate from `herdr-review' so that a caller arranging its own
windows does not have to undo a `pop-to-buffer' first.  This is the
form `herdr-ui-panels' names to put the panel in a column."
  (let ((buffer (get-buffer-create herdr-review-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-review-mode)
        (herdr-review-mode))
      (herdr-panel-watch)
      (herdr-review-refresh))
    buffer))

;;;###autoload
(defun herdr-review-visit (pane &optional other)
  "Show the terminal for the review running in PANE.
PANE is read with completion over the reviews herdr is reporting, the
ones waiting on you first, exactly as the panel lists them.  With a
prefix argument OTHER, open it the other way round from
`herdr-panel-visit-access', as pressing RET on the row would.

This goes to a review that is already open.  `herdr-review-open' is
what starts one."
  (interactive (list (herdr-review--read) current-prefix-arg))
  (herdr-panel-open-pane pane (herdr-panel-access other)))

(defun herdr-review--read ()
  "Read a review with completion and return the pane holding it."
  (herdr-panel-ensure-session)
  (let ((reviews (herdr-review-list))
        (current (herdr-panel-current-pane)))
    (unless reviews
      (user-error "Nothing is waiting to be reviewed"))
    (herdr-panel-read-pane
     "Review: "
     (mapcar (lambda (review)
               (cons (herdr-panel-entry-line
                      (herdr-review--entry review current))
                     (gethash "pane_id" review)))
             reviews))))

(defun herdr-review-refresh ()
  "Redraw the reviews panel from the session tree."
  (interactive)
  (with-current-buffer (get-buffer-create herdr-review-buffer-name)
    (herdr-panel-with-redraw
      (magit-insert-section (herdr-review-root)
        (herdr-panel-insert-title
         "Reviews" (and herdr-review-border 'herdr-panel-border))
        (let ((reviews (herdr-review-list))
              (current (herdr-panel-current-pane)))
          (if reviews
              (dolist (review reviews)
                (herdr-review--insert review current))
            (insert (propertize "  nothing to review\n"
                                'face 'herdr-panel-unknown))))))
    (herdr-panel-settle-point)))

;;;###autoload
(defun herdr-review-open (&optional workspace)
  "Open a review of WORKSPACE, or go to the one it already has.
WORKSPACE defaults to the one holding the row at point, and failing
that the one holding the pane you are looking at.  The review runs in
a tab of its own, and this shows that tab's terminal here."
  (interactive (list (herdr-review--workspace-at-point)))
  (let ((workspace (or workspace (herdr-review--current-workspace))))
    (unless workspace
      (user-error "No workspace to review"))
    (let ((pane (herdr-review--run "open" "--workspace" workspace)))
      (herdr-session-refresh 'force)
      (when pane
        (herdr-panel-open-pane pane 'control)))))

;;;###autoload
(defun herdr-review-close (&optional workspace)
  "End the review of WORKSPACE, closing its tab.
WORKSPACE defaults the same way as in `herdr-review-open'.  The review
ends itself when you quit the review tool, so this is for the one you
walked away from."
  (interactive (list (herdr-review--workspace-at-point)))
  (let ((workspace (or workspace (herdr-review--current-workspace))))
    (unless workspace
      (user-error "No workspace whose review to close"))
    (herdr-review--run "close" "--workspace" workspace)
    (herdr-session-refresh 'force)))

;;; Reading the Session

(defun herdr-review-list ()
  "Return the reviews herdr is reporting, the ones waiting first.
A review is an agent of kind `herdr-review-agent', which is what the
herdr-review script reports each one as."
  (seq-sort-by (lambda (review)
                 (herdr-session-status-priority
                  (gethash "agent_status" review)))
               #'>
               (seq-filter (lambda (agent)
                             (equal (gethash "agent" agent)
                                    herdr-review-agent))
                           (herdr-session-agents))))

(defun herdr-review--current-workspace ()
  "Return the workspace holding the pane you are looking at, or nil."
  (when-let* ((pane-id (herdr-panel-current-pane))
              (pane (herdr-session-pane pane-id)))
    (gethash "workspace_id" pane)))

(defun herdr-review--workspace-at-point ()
  "Return the workspace of the row at point, or nil when there is none.
Asked of the panel rather than read off the row, through the function
every panel gives `herdr-panel-init': a spaces row, an agent row and a
review row all answer with a pane, and the pane names the workspace.
So a review can be opened from any panel, and none of their rendering
is this file's business."
  (when-let* ((at-point herdr-panel-pane-function)
              (pane-id (ignore-errors (funcall at-point)))
              (pane (herdr-session-pane pane-id)))
    (gethash "workspace_id" pane)))

;;; Rendering

(defun herdr-review--entry (review current)
  "Return the row for REVIEW, emphasised against the CURRENT pane.
The workspace names the row, because one review per workspace makes
the workspace the thing being reviewed.  What is under review goes
beneath it, as the script counted it when the review opened."
  (list :status (gethash "agent_status" review)
        :emphasis (herdr-panel-emphasis (gethash "pane_id" review) current)
        :label (herdr-review--label review)
        :aside (herdr-panel-text herdr-review-icon 'herdr-review-icon)
        :detail (herdr-review--summary review)))

(defun herdr-review--insert (review current)
  "Insert an entry for REVIEW, emphasised against the CURRENT pane."
  (magit-insert-section (herdr-review-entry (gethash "pane_id" review))
    (herdr-panel-insert-entry (herdr-review--entry review current))))

(defun herdr-review--label (review)
  "Return the name of the workspace REVIEW is reviewing."
  (let ((id (gethash "workspace_id" review)))
    (or (when-let* ((workspace (herdr-session-workspace id)))
          (gethash "label" workspace))
        id)))

(defun herdr-review--summary (review)
  "Return the note REVIEW carries about what is waiting, or nil.
The script puts this on the pane as a display-only metadata token, so
it is herdr's own word for it rather than something read back out of
the terminal."
  (when-let* ((tokens (gethash "tokens" review)))
    (gethash "summary" tokens)))

(defun herdr-review--pane-at-point ()
  "Return the pane of the row at point, or signal when there is none."
  (let ((section (magit-current-section)))
    (or (and section
             (eq (oref section type) 'herdr-review-entry)
             (oref section value))
        (user-error "No review at point"))))

;;; Running the Script

(defun herdr-review--run (&rest arguments)
  "Run the herdr-review script with ARGUMENTS and return the pane it names.
Signals when the script is missing or fails, with what it printed on
its error stream, because a review that silently did not open looks
the same as one nobody asked for."
  (unless (executable-find herdr-review-program)
    (user-error "Cannot find %s; set `herdr-review-program'"
                herdr-review-program))
  (with-temp-buffer
    (let ((status (apply #'call-process herdr-review-program nil t nil
                         arguments)))
      (unless (eq status 0)
        (user-error "Cannot %s the review: %s" (car arguments)
                    (string-trim (buffer-string))))
      (goto-char (point-min))
      (let ((reply (ignore-errors (json-parse-buffer))))
        (and (hash-table-p reply) (gethash "pane_id" reply))))))

;;; Fitting Into herdr

;; The panel's place in the column is already held for it, in the default
;; value of `herdr-ui-panels'; the layout leaves that entry out until this
;; file defines the function it names.  Only the hiding has to be asked
;; for, and asking for it on load rather than in the user's configuration
;; is what makes requiring this file the whole of the setup.

(add-to-list 'herdr-agents-hidden-kinds herdr-review-agent)

;;; _
(provide 'herdr-review)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-review.el ends here
