;;; herdr-ui-tests.el --- Tests for herdr-ui  -*- lexical-binding:t -*-

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

;; The column is a list of panels and the weight each takes of it, and an
;; entry may name a panel from a file that is not loaded.  What is worth
;; testing is the arithmetic that turns weights into shares, and that an
;; optional panel costs nothing while its file is absent.

;; Windows are never made: `herdr-ui--display' is replaced, so a test says
;; what the layout would be rather than building one on a batch frame.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-panel-tests)
(require 'herdr-session-tests)
(require 'herdr-ui)

;; Declared rather than required: the tab commands read the pane a herdr
;; terminal mirrors, and these tests bind it themselves rather than pull
;; in herdr-term and, with it, ghostel and a native module.
(defvar herdr-term--pane)

;;; Fixtures

(defvar herdr-ui-tests--shown nil
  "What `herdr-ui--display' was asked to show, in order.
Each entry has the form (BUFFER-NAME SLOT . HEIGHT).")

(defmacro herdr-ui-with-layout (&rest body)
  "Evaluate BODY with the column empty and no windows made.
`herdr-ui-tests--shown' collects what the layout asked for.
`herdr-ui-panels' is restored afterwards, so a test cannot leak a
panel into the next one."
  (declare (indent 0) (debug t))
  `(let ((herdr-ui-panels nil)
         (herdr-ui-tests--shown nil))
     (cl-letf (((symbol-function 'herdr-ui--display)
                (lambda (buffer slot height)
                  ;; Appended rather than pushed, so that a test reading
                  ;; the list mid-body reads it top of column first.
                  (setq herdr-ui-tests--shown
                        (append herdr-ui-tests--shown
                                (list (cons (buffer-name buffer)
                                            (cons slot height)))))
                  buffer)))
       ,@body)))

(defun herdr-ui-tests--panel (name)
  "Return a function standing in for a panel whose buffer is called NAME."
  (lambda () (get-buffer-create name)))

;;; Leaving Out A Panel That Is Not Loaded

(ert-deftest herdr-ui--show-panels:skips-an-undefined-panel ()
  "An entry naming a file that is not loaded is passed over.
This is what lets an optional panel keep its place in the order at no
cost: `herdr-tuicr' is not loaded with the rest of herdr, and the
layout must stand without it rather than signal."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 1)
                            (herdr-ui-tests--panel-that-is-not-defined . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'car herdr-ui-tests--shown) '("spaces")))))

(ert-deftest herdr-ui--show-panels:shares-out-what-a-missing-panel-left ()
  "The panels that are there divide the whole column between them.
A skipped entry must not leave a gap, or an uninstalled optional panel
would cost room for nothing."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 3)
                            (,(herdr-ui-tests--panel "agents") . 2)
                            (herdr-ui-tests--panel-that-is-not-defined . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cddr herdr-ui-tests--shown)
                   (list (/ 3.0 5) (/ 2.0 5))))))

;;; Sharing The Column

(ert-deftest herdr-ui--show-panels:divides-the-column-by-weight ()
  "Weights are shares of their own total, not fractions of the frame.
That is what lets a panel be added without every other weight having to
be rewritten."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 3)
                            (,(herdr-ui-tests--panel "agents") . 2)
                            (,(herdr-ui-tests--panel "reviews") . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cddr herdr-ui-tests--shown)
                   (list (/ 3.0 6) (/ 2.0 6) (/ 1.0 6))))))

(ert-deftest herdr-ui--show-panels:stacks-in-order ()
  "Slots increase down the column, so the first entry is the top one."
  (herdr-ui-with-layout
    (setq herdr-ui-panels `((,(herdr-ui-tests--panel "spaces") . 1)
                            (,(herdr-ui-tests--panel "agents") . 1)))
    (herdr-ui--show-panels)
    (should (equal (mapcar #'cadr herdr-ui-tests--shown) '(0 1)))))

(ert-deftest herdr-ui--show-panels:shows-nothing-when-there-is-nothing ()
  "An empty column is empty rather than a division by zero."
  (herdr-ui-with-layout
    (herdr-ui--show-panels)
    (should (null herdr-ui-tests--shown))))

;;; Passing The Column By

;; These call the real `herdr-ui--display', which the fixture above stubs
;; out, so they make a window and take it down again.

(defmacro herdr-ui-tests-with-panel (name &rest body)
  "Evaluate BODY with a panel window called NAME on the frame.
The window is deleted afterwards, and the frame is left holding the one
window it started with."
  (declare (indent 1) (debug t))
  `(let ((buffer (get-buffer-create ,name)))
     (unwind-protect
         (save-selected-window
           (herdr-ui--display buffer 0 1.0)
           ,@body)
       (when-let* ((window (get-buffer-window buffer)))
         (delete-window window))
       (kill-buffer buffer))))

(ert-deftest herdr-ui--display:passes-the-panels-by ()
  "`C-x o' moves between the windows you work in, not the furniture.
A panel is reached by the command that names it, so counting it in the
cycle spends a keystroke on a window nobody meant to land in.

`other-window' is what reads the parameter; `next-window' returns a
skipped window like any other, so the move itself is what to assert."
  (herdr-ui-tests-with-panel " *herdr-ui-test-panel*"
    (let ((panel (get-buffer-window buffer))
          (working (selected-window)))
      (should (window-parameter panel 'no-other-window))
      ;; There is somewhere else to land, or staying put says nothing.
      (should (memq panel (window-list)))
      (other-window 1)
      (should (eq (selected-window) working)))))

(ert-deftest herdr-ui--display:stops-on-a-panel-when-asked ()
  "The cycle takes the panels back when the option says so."
  (let ((herdr-ui-panel-other-window 'stop))
    (herdr-ui-tests-with-panel " *herdr-ui-test-panel*"
      (let ((panel (get-buffer-window buffer)))
        (should-not (window-parameter panel 'no-other-window))
        (other-window 1)
        (should (eq (selected-window) panel))))))

;;; Quitting

(ert-deftest herdr-ui-quit:kills-panels-and-spares-terminals ()
  "Quitting takes down the furniture, not the work.
A panel left alive would go on asking a stopped session to redraw it,
while a terminal mirroring a pane is what the user was doing."
  (let ((panel (generate-new-buffer "*herdr-test-panel*"))
        (terminal (generate-new-buffer "*herdr-test-terminal*")))
    (unwind-protect
        (progn
          (with-current-buffer panel
            (setq-local herdr-panel-refresh-function #'ignore))
          (with-current-buffer terminal
            (setq-local herdr-term--pane "w1:p1"))
          (cl-letf (((symbol-function 'herdr-session-stop) #'ignore))
            (herdr-ui-quit))
          (should-not (buffer-live-p panel))
          (should (buffer-live-p terminal)))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (buffer-live-p terminal) (kill-buffer terminal)))))

;;; Reaching Any Terminal Of The Session

(defmacro herdr-ui-with-session (&rest body)
  "Evaluate BODY with a session of two panes, one of them running codex.
Git is left unasked: it would run a subprocess against a directory no
fixture has, and none of what it answers is what these tests are
about."
  (declare (indent 0) (debug t))
  `(let ((herdr-spaces-git nil)
         (herdr-agents-icons '(("codex" . "◆"))))
     (herdr-session-with-snapshot
         (list :workspaces
               (vector (list :workspace_id "w1" :label "project"
                             :active_tab_id "w1:t1" :tab_count 1
                             :agent_status "idle"))
               :tabs
               (vector (list :tab_id "w1:t1" :workspace_id "w1"
                             :label "1" :agent_status "idle"))
               :panes
               (vector (list :pane_id "w1:p1" :workspace_id "w1"
                             :tab_id "w1:t1" :cwd "/tmp/project"
                             :agent "codex" :agent_status "idle")
                       (list :pane_id "w1:p2" :workspace_id "w1"
                             :tab_id "w1:t1" :cwd "/tmp/project"
                             :agent_status "idle")))
       ,@body)))

(ert-deftest herdr-ui--pane-entry:names-the-workspace-and-the-pane ()
  "A row flattened into a prompt has to say which workspace it is in.
The panel can put a pane under a heading; a candidate stands alone."
  (herdr-ui-with-session
    (let ((entry (herdr-ui--pane-entry (car (herdr-session-panes)) nil)))
      (should (equal (substring-no-properties (plist-get entry :label))
                     "project (w1:p1)")))))

(ert-deftest herdr-ui--pane-entry:shows-the-agent-as-its-glyph ()
  "The glyph carries the kind on its own, so the name is not repeated."
  (herdr-ui-with-session
    (let ((entry (herdr-ui--pane-entry (car (herdr-session-panes)) nil)))
      (should (equal (substring-no-properties (plist-get entry :aside))
                     "◆"))
      (should-not (string-match-p "codex"
                                  (substring-no-properties
                                   (plist-get entry :label)))))))

(ert-deftest herdr-ui--pane-entry:leaves-the-glyph-out-of-a-plain-shell ()
  "A pane herdr recognised nothing in carries no agent glyph."
  (herdr-ui-with-session
    (let ((entry (herdr-ui--pane-entry (cadr (herdr-session-panes)) nil)))
      (should-not (plist-get entry :aside)))))

(ert-deftest herdr-ui--pane-entry:opens-the-row-with-the-status ()
  "The status mark leads the row, ahead of every other field."
  (herdr-ui-with-session
    (let* ((pane (car (herdr-session-panes)))
           (line (substring-no-properties
                  (herdr-panel-entry-line (herdr-ui--pane-entry pane nil)))))
      (should (string-prefix-p
               (substring-no-properties
                (herdr-panel-status-string (herdr-session-status pane)))
               line)))))

(ert-deftest herdr-ui--read-pane:offers-every-pane-of-the-session ()
  "Both panes are offered, the plain shell as well as the agent's."
  (herdr-ui-with-session
    (herdr-panel-tests-offline
      (herdr-panel-tests-choosing 1
        (should (equal (herdr-ui--read-pane) "w1:p2"))
        (should (eql (length herdr-panel-tests--offered) 2))))))

(ert-deftest herdr-ui--read-pane:refuses-an-empty-session ()
  "No panes says so rather than raising an empty prompt."
  (let ((herdr-spaces-git nil))
    (herdr-session-with-snapshot (list :workspaces (vector) :panes (vector))
      (herdr-panel-tests-offline
        (should-error (herdr-ui--read-pane) :type 'user-error)))))

;;; Tabs Of The Terminal's Workspace

(defvar herdr-ui-tests--asked nil
  "Calls `herdr-api-request' was given, as (METHOD . PARAMS), newest first.")

(defvar herdr-ui-tests--visited nil
  "The tab `herdr-ui-visit-tab' was last asked to show.")

(defvar herdr-ui-tests--opened nil
  "The pane `herdr-panel-open-pane' was last asked to show.")

(defun herdr-ui-tests--node (&rest fields)
  "Return a herdr node carrying FIELDS, given as KEY VALUE pairs."
  (let ((node (make-hash-table :test #'equal)))
    (while fields
      (puthash (pop fields) (pop fields) node))
    node))

(defmacro herdr-ui-with-tabs (tabs current &rest body)
  "Evaluate BODY with the pane at hand in CURRENT, of a workspace of TABS.
TABS is a list of tab identifiers in the order herdr reports them, and
CURRENT is the one holding the pane the buffer mirrors, which is what
every tab command starts from.

`herdr-api-request' answers `tab.list' with TABS and `pane.list' with
one pane per tab, `w1:tN' holding `w1:pN'.  Every other call answers an
empty object.  Each is recorded in `herdr-ui-tests--asked'.

The session tree reports no pane at all, which is the state a walk
meets when it steps onto a tab made a keystroke ago.  So
`herdr-ui-visit-tab' runs for real here — it is where such a walk used
to fail, by resolving against the tree the walk had just routed around
— and only the terminal it would open is stubbed out."
  (declare (indent 2) (debug t))
  `(let ((herdr-ui-tests--asked nil)
         (herdr-ui-tests--visited nil)
         (herdr-ui-tests--opened nil)
         (herdr-term--pane "w1:p1"))
     (cl-letf (((symbol-function 'herdr-session-pane)
                (lambda (_pane)
                  (herdr-ui-tests--node "tab_id" ,current
                                        "workspace_id" "w1")))
               ((symbol-function 'herdr-session-panes) (lambda (&rest _) nil))
               ((symbol-function 'herdr-api-request)
                (lambda (method &optional params)
                  (push (cons method params) herdr-ui-tests--asked)
                  (cond
                    ((equal method "tab.list")
                     (herdr-ui-tests--node
                      "tabs" (vconcat
                              (mapcar (lambda (id)
                                        (herdr-ui-tests--node "tab_id" id))
                                      ,tabs))))
                    ((equal method "pane.list")
                     (herdr-ui-tests--node
                      "panes"
                      (vconcat
                       (mapcar
                        (lambda (id)
                          (herdr-ui-tests--node
                           "tab_id" id
                           "pane_id" (replace-regexp-in-string
                                      ":t" ":p" id)))
                        ,tabs))))
                    (t (herdr-ui-tests--node)))))
               ((symbol-function 'herdr-panel-open-pane)
                (lambda (pane &optional _access)
                  (setq herdr-ui-tests--visited pane
                        herdr-ui-tests--opened pane))))
       ,@body)))

(defmacro herdr-ui-with-new-tab (&rest body)
  "Evaluate BODY with `tab.create' answering with a tab and its pane.
The fixture above answers every call with an empty object, which is
what a command must survive rather than what it usually meets."
  (declare (indent 0) (debug t))
  `(let ((answer (symbol-function 'herdr-api-request)))
     (cl-letf (((symbol-function 'herdr-api-request)
                (lambda (method &optional params)
                  (funcall answer method params)
                  (if (equal method "tab.create")
                      (herdr-ui-tests--node
                       "root_pane" (herdr-ui-tests--node "pane_id" "w1:p9"))
                    (herdr-ui-tests--node)))))
       ,@body)))

(ert-deftest herdr-ui-tab-new:shows-the-pane-of-the-tab-it-made ()
  "The command lands in the new tab rather than merely making it."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-with-new-tab
      (herdr-ui-tab-new)
      (should (equal (caar herdr-ui-tests--asked) "tab.create"))
      (should (equal herdr-ui-tests--opened "w1:p9")))))

(ert-deftest herdr-ui-tab-new:names-this-terminal-s-workspace ()
  "The tab is made in the workspace of the pane the buffer mirrors."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-with-new-tab
      (herdr-ui-tab-new)
      (should (equal (plist-get (cdar herdr-ui-tests--asked) :workspace_id)
                     "w1")))))

(ert-deftest herdr-ui-tab-new:carries-a-label-when-one-is-given ()
  "A label given names the tab; none leaves herdr to number it."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-with-new-tab
      (herdr-ui-tab-new "spike")
      (should (equal (plist-get (cdar herdr-ui-tests--asked) :label)
                     "spike"))))
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-with-new-tab
      (herdr-ui-tab-new)
      (should-not (plist-member (cdar herdr-ui-tests--asked) :label)))))

(ert-deftest herdr-ui-tab-new:reports-an-answer-it-cannot-use ()
  "A reply naming no pane is ours to report, not the API's."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (let ((error-data (should-error (herdr-ui-tab-new) :type 'user-error)))
      (should (string-match-p "named no pane" (cadr error-data))))))

(ert-deftest herdr-ui-tab-new:leaves-herdr-focused-where-it-was ()
  "Focus is never asked for, because Emacs is itself in a herdr pane.
Moving herdr's focus onto the new tab would send the keyboard there
and take it away from this Emacs."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-with-new-tab
      (herdr-ui-tab-new)
      (should-not (plist-member (cdar herdr-ui-tests--asked) :focus)))))

(ert-deftest herdr-ui-tab-rename:names-the-tab-and-the-label ()
  "The rename carries the tab of this terminal and the label given."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (herdr-ui-tab-rename "spike")
    (should (equal (caar herdr-ui-tests--asked) "tab.rename"))
    (should (equal (plist-get (cdar herdr-ui-tests--asked) :tab_id)
                   "w1:t1"))
    (should (equal (plist-get (cdar herdr-ui-tests--asked) :label)
                   "spike"))))

(ert-deftest herdr-ui--step-tab:moves-along-the-workspace ()
  "Next shows the tab herdr reports after this one."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2" "w1:t3") "w1:t1"
    (herdr-ui-tab-next)
    (should (equal herdr-ui-tests--visited "w1:p2"))))

(ert-deftest herdr-ui--step-tab:wraps-at-the-last ()
  "Walking past the last tab of a workspace returns to its first."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2" "w1:t3") "w1:t3"
    (herdr-ui-tab-next)
    (should (equal herdr-ui-tests--visited "w1:p1"))))

(ert-deftest herdr-ui--step-tab:runs-the-other-way-back ()
  "Previous walks the same tabs in the opposite order, and wraps too."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2" "w1:t3") "w1:t3"
    (herdr-ui-tab-previous)
    (should (equal herdr-ui-tests--visited "w1:p2")))
  (herdr-ui-with-tabs '("w1:t1" "w1:t2" "w1:t3") "w1:t1"
    (herdr-ui-tab-previous)
    (should (equal herdr-ui-tests--visited "w1:p3"))))

(ert-deftest herdr-ui--step-tab:refuses-when-the-workspace-holds-one ()
  "A workspace of one tab has nowhere to move to, and says so."
  (herdr-ui-with-tabs '("w1:t1") "w1:t1"
    (should-error (herdr-ui-tab-next) :type 'user-error)))

(ert-deftest herdr-ui--step-tab:refuses-when-herdr-reports-no-tabs ()
  "An empty answer is refused rather than walked as though it held one."
  (herdr-ui-with-tabs '() "w1:t1"
    (should-error (herdr-ui-tab-next) :type 'user-error)))

(ert-deftest herdr-ui--tabs:asks-herdr-rather-than-the-tree ()
  "A tab made a keystroke ago is not in the session tree yet.
Read from the tree, a walk taken straight after making a tab would step
past the very tab it was asked to make."
  (cl-letf (((symbol-function 'herdr-session-tabs)
             (lambda (&rest _) (error "The tree must not be read here")))
            ((symbol-function 'herdr-api-request)
             (lambda (&rest _)
               (json-parse-string
                "{\"tabs\":[{\"tab_id\":\"w1:t1\"},{\"tab_id\":\"w1:t2\"}]}"))))
    (should (equal (herdr-ui--tabs "w1") '("w1:t1" "w1:t2")))))

(ert-deftest herdr-ui--tabs:tolerates-an-answer-carrying-none ()
  "A result with no tabs is empty, not malformed."
  (cl-letf (((symbol-function 'herdr-api-request)
             (lambda (&rest _) (json-parse-string "{}"))))
    (should (null (herdr-ui--tabs "w1")))))

(ert-deftest herdr-ui-tab-close:closes-the-tab-once-answered-for ()
  "Saying yes closes the tab this terminal sits in."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2") "w1:t1"
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (herdr-ui-tab-close)
      (should (equal (car herdr-ui-tests--asked)
                     '("tab.close" :tab_id "w1:t1"))))))

(ert-deftest herdr-ui-tab-close:takes-the-mirroring-buffers-with-it ()
  "The buffers of the closed tab's panes go when the tab does.
A stream whose pane has gone takes its own buffer down a moment later,
so this is about when rather than whether.  A buffer that mirrors
nothing is left alone, which is every buffer in an Emacs that has a
value for the pane variable but no local binding of it."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2") "w1:t1"
    (let ((mirror (generate-new-buffer "*herdr-ui-test-mirror*"))
          (bystander (generate-new-buffer "*herdr-ui-test-bystander*")))
      (unwind-protect
          (progn
            (with-current-buffer mirror
              (setq-local herdr-term--pane "w1:p1"))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (herdr-ui-tab-close))
            (should-not (buffer-live-p mirror))
            (should (buffer-live-p bystander)))
        (when (buffer-live-p mirror) (kill-buffer mirror))
        (when (buffer-live-p bystander) (kill-buffer bystander))))))

(ert-deftest herdr-ui-tab-close:leaves-the-tab-alone-when-refused ()
  "Saying no spends no call.
The tab and every pane in it would go for every client of the session."
  (herdr-ui-with-tabs '("w1:t1" "w1:t2") "w1:t1"
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (herdr-ui-tab-close) :type 'user-error)
      (should (null herdr-ui-tests--asked)))))

(ert-deftest herdr-ui--pane-node:asks-herdr-for-what-the-tree-lacks ()
  "A pane made a keystroke ago is not in the session tree yet.
Left to the tree alone, a tab command would refuse to act on the very
pane it was just given."
  (cl-letf (((symbol-function 'herdr-session-pane) (lambda (&rest _) nil))
            ((symbol-function 'herdr-api-request)
             (lambda (&rest _)
               (json-parse-string
                "{\"pane\":{\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t1\"}}"))))
    (should (equal (gethash "tab_id" (herdr-ui--pane-node "w1:p2"))
                   "w1:t1"))))

(ert-deftest herdr-ui--pane-node:spends-no-call-on-what-the-tree-has ()
  "The tree answers when it can, so a walk costs no connection."
  (cl-letf (((symbol-function 'herdr-session-pane)
             (lambda (&rest _)
               (let ((node (make-hash-table :test #'equal)))
                 (puthash "tab_id" "w1:t1" node)
                 node)))
            ((symbol-function 'herdr-api-request)
             (lambda (&rest _) (error "Herdr must not be asked here"))))
    (should (equal (gethash "tab_id" (herdr-ui--pane-node "w1:p1"))
                   "w1:t1"))))

(ert-deftest herdr-ui--this-pane:refuses-outside-a-terminal ()
  "A buffer mirroring nothing has no tab for a command to act on."
  (with-temp-buffer
    (should-error (herdr-ui--this-pane) :type 'user-error)))

;;; _
(provide 'herdr-ui-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-ui-tests.el ends here
