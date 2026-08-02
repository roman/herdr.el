;;; herdr-tuicr.el --- Drive tuicr reviews from herdr  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>

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
;; start and end one.  A review is a tuicr TUI running in a tab of its own
;; called "review", inside the workspace whose code is under review.

;; herdr has no idea what tuicr is, and does not need one.  The review
;; reports itself over the socket as an agent of kind "tuicr", so herdr
;; rolls its state up to the tab and the workspace exactly as it does for
;; a coding agent, and every herdr client sees a blocked review without
;; being taught anything.  That reporting is done by the `herdr-review'
;; script from the herdr-tuicr project, which is also what a coding agent
;; runs when it wants a change looked at; this file is a third caller of
;; it rather than a second implementation.

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

(defgroup herdr-tuicr nil
  "Code reviews in herdr, run by tuicr."
  :group 'herdr-panel
  :link '(url-link "https://github.com/roman/herdr-tuicr"))

(defcustom herdr-tuicr-program "herdr-review"
  "The herdr-review script, which starts and ends a review.
Named rather than reimplemented so that a review begun from Emacs, from
a shell, or by a coding agent is the same review.  It comes from the
herdr-tuicr project, which is where the review lifecycle lives and which
needs none of Emacs; put its full path here when that project's `bin'
directory is not on the variable `exec-path'."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-tuicr
  :type 'string)

(defconst herdr-tuicr-agent "tuicr"
  "The kind of agent a review reports itself as.
This is what tells a review apart from a coding agent in everything
herdr reports.  Not an option, because the same string is written by
the `herdr-tuicr-program' script and read here: one of the two would
always be free to disagree with the other.")

(defcustom herdr-tuicr-buffer-name "*herdr-reviews*"
  "Name of the buffer showing the reviews panel."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-tuicr
  :type 'string)

(defcustom herdr-tuicr-border t
  "Whether to rule the reviews panel off from the panel above it.
The panels share a column with no mode line between them, so without a
rule they read as one list under several headings."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-tuicr
  :type 'boolean)

(defcustom herdr-tuicr-icon "⌥"
  "Glyph shown beside a review, in place of the agent kind."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-tuicr
  :type 'string)

;;; Faces

(defface herdr-tuicr-icon
  '((((background dark)) :foreground "#7aa2f7")
    (((background light)) :foreground "#2f5fbf")
    (t :inherit font-lock-keyword-face))
  "Face for the mark beside a review."
  :group 'herdr-tuicr)

;;; Keymaps

(defvar-keymap herdr-tuicr-mode-map
  :doc "Keymap for `herdr-tuicr-mode'."
  :parent herdr-panel-mode-map
  "+" #'herdr-tuicr-open
  "-" #'herdr-tuicr-close)

(with-eval-after-load 'evil
  (herdr-panel-install-evil-keys herdr-tuicr-mode-map))

;;; Mode

(define-derived-mode herdr-tuicr-mode magit-section-mode "Herdr Reviews"
  "Major mode for the herdr reviews panel."
  :interactive nil
  (herdr-panel-init #'herdr-tuicr-refresh #'herdr-tuicr--pane-at-point))

;;; Commands

;;;###autoload
(defun herdr-tuicr-reviews ()
  "Show the panel listing the reviews waiting to be read."
  (interactive)
  (pop-to-buffer (herdr-tuicr-panel)))

(defun herdr-tuicr-panel ()
  "Return the reviews buffer, drawn and tracking the session.
Separate from `herdr-tuicr-reviews' so that a caller arranging its own
windows does not have to undo a `pop-to-buffer' first.  This is the
form `herdr-ui-panels' names to put the panel in a column."
  (let ((buffer (get-buffer-create herdr-tuicr-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-tuicr-mode)
        (herdr-tuicr-mode))
      (herdr-panel-watch)
      (herdr-tuicr-refresh))
    buffer))

(defun herdr-tuicr-refresh ()
  "Redraw the reviews panel from the session tree."
  (interactive)
  (with-current-buffer (get-buffer-create herdr-tuicr-buffer-name)
    (herdr-panel-with-redraw
      (magit-insert-section (herdr-tuicr-root)
        (herdr-panel-insert-title
         "Reviews" (and herdr-tuicr-border 'herdr-panel-border))
        (let ((reviews (herdr-tuicr-reviews-list))
              (current (herdr-panel-current-pane)))
          (if reviews
              (dolist (review reviews)
                (herdr-tuicr--insert review current))
            (insert (propertize "  nothing to review\n"
                                'face 'herdr-panel-unknown))))))
    (herdr-panel-settle-point)))

;;;###autoload
(defun herdr-tuicr-open (&optional workspace)
  "Open a review of WORKSPACE, or go to the one it already has.
WORKSPACE defaults to the one holding the row at point, and failing
that the one holding the pane you are looking at.  The review runs in
a tab of its own, and this shows that tab's terminal here."
  (interactive (list (herdr-tuicr--workspace-at-point)))
  (let ((workspace (or workspace (herdr-tuicr--current-workspace))))
    (unless workspace
      (user-error "No workspace to review"))
    (let ((pane (herdr-tuicr--run "open" "--workspace" workspace)))
      (herdr-session-refresh 'force)
      (when pane
        (herdr-panel-open-pane pane 'control)))))

;;;###autoload
(defun herdr-tuicr-close (&optional workspace)
  "End the review of WORKSPACE, closing its tab.
WORKSPACE defaults the same way as in `herdr-tuicr-open'.  The review
ends itself when you quit the tuicr TUI, so this is for the one you
walked away from."
  (interactive (list (herdr-tuicr--workspace-at-point)))
  (let ((workspace (or workspace (herdr-tuicr--current-workspace))))
    (unless workspace
      (user-error "No workspace whose review to close"))
    (herdr-tuicr--run "close" "--workspace" workspace)
    (herdr-session-refresh 'force)))

;;; Reading the Session

(defun herdr-tuicr-reviews-list ()
  "Return the reviews herdr is reporting, the ones waiting first.
A review is an agent of kind `herdr-tuicr-agent', which is what the
herdr-review script reports each one as."
  (seq-sort-by (lambda (review)
                 (herdr-session-status-priority
                  (gethash "agent_status" review)))
               #'>
               (seq-filter (lambda (agent)
                             (equal (gethash "agent" agent)
                                    herdr-tuicr-agent))
                           (herdr-session-agents))))

(defun herdr-tuicr--current-workspace ()
  "Return the workspace holding the pane you are looking at, or nil."
  (when-let* ((pane-id (herdr-panel-current-pane))
              (pane (herdr-session-pane pane-id)))
    (gethash "workspace_id" pane)))

(defun herdr-tuicr--workspace-at-point ()
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

(defun herdr-tuicr--insert (review current)
  "Insert an entry for REVIEW, emphasised against the CURRENT pane.
The workspace names the row, because one review per workspace makes
the workspace the thing being reviewed.  What is under review goes
beneath it, as the script counted it when the review opened."
  (let ((pane (gethash "pane_id" review)))
    (magit-insert-section (herdr-tuicr-review pane)
      (herdr-panel-insert-entry
       (list :status (gethash "agent_status" review)
             :emphasis (herdr-panel-emphasis pane current)
             :label (herdr-tuicr--label review)
             :aside (herdr-panel-text herdr-tuicr-icon 'herdr-tuicr-icon)
             :detail (herdr-tuicr--summary review))))))

(defun herdr-tuicr--label (review)
  "Return the name of the workspace REVIEW is reviewing."
  (let ((id (gethash "workspace_id" review)))
    (or (when-let* ((workspace (herdr-session-workspace id)))
          (gethash "label" workspace))
        id)))

(defun herdr-tuicr--summary (review)
  "Return the note REVIEW carries about what is waiting, or nil.
The script puts this on the pane as a display-only metadata token, so
it is herdr's own word for it rather than something read back out of
the terminal."
  (when-let* ((tokens (gethash "tokens" review)))
    (gethash "summary" tokens)))

(defun herdr-tuicr--pane-at-point ()
  "Return the pane of the row at point, or signal when there is none."
  (let ((section (magit-current-section)))
    (or (and section
             (eq (oref section type) 'herdr-tuicr-review)
             (oref section value))
        (user-error "No review at point"))))

;;; Running the Script

(defun herdr-tuicr--run (&rest arguments)
  "Run the herdr-review script with ARGUMENTS and return the pane it names.
Signals when the script is missing or fails, with what it printed on
its error stream, because a review that silently did not open looks
the same as one nobody asked for."
  (unless (executable-find herdr-tuicr-program)
    (user-error "Cannot find %s; set `herdr-tuicr-program'"
                herdr-tuicr-program))
  (with-temp-buffer
    (let ((status (apply #'call-process herdr-tuicr-program nil t nil
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

(add-to-list 'herdr-agents-hidden-kinds herdr-tuicr-agent)

;;; _
(provide 'herdr-tuicr)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-tuicr.el ends here
