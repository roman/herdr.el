;;; herdr-machines-tests.el --- Test machines  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This file is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Saved machine parsing, status transitions and panel rendering.

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'herdr-machines)
(require 'herdr-session-tests)

(defun herdr-machines-tests--profile (&optional enabled)
  "Return a Baker profile whose ENABLED state is explicit."
  (let ((profile (make-hash-table :test #'equal)))
    (puthash "id" "0123456789abcdef0123456789abcdef" profile)
    (puthash "label" "baker" profile)
    (puthash "target" "roman@baker.zoo.internal" profile)
    (puthash "session" "default" profile)
    (puthash "enabled" enabled profile)
    profile))

(ert-deftest herdr-machines--status:starts-enabled-machines-connecting ()
  "An enabled machine starts in the connecting state."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (should (eq (herdr-machines--status
                 (herdr-machines-tests--profile t))
                'connecting))))

(ert-deftest herdr-machines--status:keeps-disabled-machines-disabled ()
  "A disabled profile stays disabled without a connection probe."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (should (eq (herdr-machines--status
                 (herdr-machines-tests--profile nil))
                'disabled))))

(ert-deftest herdr-machines--read-profiles:preserves-cache-on-command-failure ()
  "A failed machine list command preserves the last valid profiles."
  (let ((herdr-machines--profiles (list (herdr-machines-tests--profile t))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _arguments) 1)))
      (should (eq (herdr-machines--read-profiles)
                  herdr-machines--profiles)))))

(ert-deftest herdr-machines--read-profiles:accepts-an-empty-list ()
  "A successful empty machine list replaces the previous profiles."
  (let ((herdr-machines--profiles (list (herdr-machines-tests--profile t))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _arguments)
                 (insert "[]")
                 0)))
      (should-not (herdr-machines--read-profiles)))))

(ert-deftest herdr-machines--probe-result:maps-success-to-online ()
  "A successful server probe marks its machine online."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result
     "machine" 0 (concat "{\"running\":true,\"socket\":\"/tmp/herdr.sock\","
                         "\"endpoint_compatible\":true,"
                         "\"capabilities\":{\"surface_interest\":true,"
                         "\"health_check\":true}}\036"
                         "{\"result\":{\"snapshot\":{"
                         "\"workspaces\":[],\"tabs\":[],"
                         "\"panes\":[],\"agents\":[]}}}\036/usr/bin/herdr"))
    (should (eq (gethash "machine" herdr-machines--statuses) 'online))))

(ert-deftest herdr-machines--probe-result:stores-the-remote-snapshot ()
  "A successful probe stores the machine session tree."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal))
        (herdr-machines--snapshots (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result
     "machine" 0 (concat "{\"running\":true,\"socket\":\"/tmp/herdr.sock\","
                         "\"endpoint_compatible\":true,"
                         "\"capabilities\":{\"surface_interest\":true,"
                         "\"health_check\":true}}\036"
                         "{\"result\":{\"snapshot\":{"
                         "\"workspaces\":[{\"workspace_id\":\"w1\"}],"
                         "\"tabs\":[],\"panes\":[],\"agents\":[]}}}\036/usr/bin/herdr"))
    (should (equal (gethash "workspace_id"
                            (aref (gethash "workspaces"
                                           (gethash "machine"
                                                    herdr-machines--snapshots))
                                  0))
                   "w1"))))

(ert-deftest herdr-machines--probe-result:rejects-a-stopped-server ()
  "A reached machine with a stopped server needs attention."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result
     "machine" 0 (concat "{\"running\":false,"
                         "\"endpoint_compatible\":true,"
                         "\"capabilities\":{\"surface_interest\":true,"
                         "\"health_check\":true}}"))
    (should (eq (gethash "machine" herdr-machines--statuses) 'attention))))

(ert-deftest herdr-machines--probe-result:maps-ssh-failure-to-reconnecting ()
  "An SSH transport failure marks its machine reconnecting."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result "machine" 255 "connection refused")
    (should (eq (gethash "machine" herdr-machines--statuses)
                'reconnecting))))

(ert-deftest herdr-machines--probe-result:maps-server-failure-to-attention ()
  "A reached host with an unusable server needs attention."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result "machine" 1 "server is incompatible")
    (should (eq (gethash "machine" herdr-machines--statuses) 'attention))))

(ert-deftest herdr-machines--probe-result:maps-ssh-permission-to-attention ()
  "An SSH permission failure needs user attention."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result
     "machine" 255 "Permission denied (publickey)")
    (should (eq (gethash "machine" herdr-machines--statuses) 'attention))))

(ert-deftest herdr-machines--probe-if-due:clears-a-disabled-machine ()
  "Disabling a machine clears the previous connection state."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal))
        (herdr-machines--probe-times (make-hash-table :test #'equal))
        (herdr-machines--probes (make-hash-table :test #'equal))
        (profile (herdr-machines-tests--profile nil)))
    (puthash "0123456789abcdef0123456789abcdef" 'online
             herdr-machines--statuses)
    (puthash "0123456789abcdef0123456789abcdef" 10
             herdr-machines--probe-times)
    (herdr-machines--probe-if-due profile)
    (should-not (gethash "0123456789abcdef0123456789abcdef"
                         herdr-machines--statuses))
    (should-not (gethash "0123456789abcdef0123456789abcdef"
                         herdr-machines--probe-times))))

(ert-deftest herdr-machines--forget-removed-profiles:clears-cached-state ()
  "Removing a saved machine clears its cached connection state."
  (let* ((profile (herdr-machines-tests--profile t))
         (herdr-machines--profiles (list profile))
         (herdr-machines--statuses (make-hash-table :test #'equal))
         (herdr-machines--probe-times (make-hash-table :test #'equal))
         (herdr-machines--probes (make-hash-table :test #'equal)))
    (puthash "0123456789abcdef0123456789abcdef" 'online
             herdr-machines--statuses)
    (herdr-machines--forget-removed-profiles nil)
    (should-not (gethash "0123456789abcdef0123456789abcdef"
                         herdr-machines--statuses))))

(ert-deftest herdr-machines--probe-result:requires-federation-capabilities ()
  "A server without federation capabilities needs attention."
  (let ((herdr-machines--statuses (make-hash-table :test #'equal)))
    (herdr-machines--record-probe-result
     "machine" 0 (concat "{\"running\":true,"
                         "\"endpoint_compatible\":true,"
                         "\"capabilities\":{\"surface_interest\":true,"
                         "\"health_check\":false}}"))
    (should (eq (gethash "machine" herdr-machines--statuses) 'attention))))

(ert-deftest herdr-machines--probe-timed-out:stops-the-probe ()
  "A probe deadline stops its process and records reconnecting."
  (let* ((herdr-machines--statuses (make-hash-table :test #'equal))
         (herdr-machines--probes (make-hash-table :test #'equal))
         (buffer (generate-new-buffer " *herdr-machine-timeout-test*"))
         (process (make-process :name "herdr-machine-timeout-test"
                                :buffer buffer
                                :command '("sh" "-c" "exec sleep 60")
                                :noquery t)))
    (unwind-protect
        (progn
          (process-put process 'herdr-machine-id "machine")
          (puthash "machine" process herdr-machines--probes)
          (herdr-machines--probe-timed-out process)
          (should-not (process-live-p process))
          (should-not (gethash "machine" herdr-machines--probes))
          (should (eq (gethash "machine" herdr-machines--statuses)
                      'reconnecting)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest herdr-machines--remote-command:finds-profile-installed-herdr ()
  "The remote command checks profile paths before it reports an error."
  (let ((command (herdr-machines--remote-command "work session")))
    (should (string-match-p "\\.nix-profile/bin/herdr" command))
    (should (string-match-p
             (regexp-quote "--session work\\ session status server --json")
             command))))

;;; _
(ert-deftest herdr-machines-read-online:skips-the-prompt-for-one-server ()
  (let ((machine '(:id "baker" :label "Baker" :status online)))
    (cl-letf (((symbol-function 'herdr-machines-refresh-online)
               (lambda () (list machine)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "Unexpected prompt"))))
      (should (eq (herdr-machines-read-online) machine)))))

(ert-deftest herdr-machines-read-online:offers-only-online-servers ()
  (let ((local '(:id "local" :label "Local" :status online))
        (online '(:id "baker" :label "Baker" :status online))
        choices)
    (cl-letf (((symbol-function 'herdr-machines-refresh-online)
               (lambda () (list local online)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq choices collection)
                 "Baker")))
      (should (eq (herdr-machines-read-online) online))
      (should (equal (mapcar #'car choices) '("Local" "Baker"))))))

(ert-deftest herdr-machines-read-online:starts-local-tracking-on-first-use ()
  (let (started)
    (cl-letf (((symbol-function 'herdr-session-live-p) (lambda () nil))
              ((symbol-function 'herdr-session-start)
               (lambda () (setq started t)))
              ((symbol-function 'herdr-machines-refresh) #'ignore)
              ((symbol-function 'herdr-machines-online-list)
               (lambda () (list '(:id "local" :status online)))))
      (herdr-machines-read-online)
      (should started))))

;;; Every Machine's Tree

(defvar herdr-machines-tests--remote nil
  "The session tree `herdr-machines-tests-with-remote' gives general-dev.")

(defmacro herdr-machines-tests-with-remote (snapshot &rest body)
  "Evaluate BODY with an online remote machine holding SNAPSHOT.
SNAPSHOT is a plist in the shape herdr answers `session.snapshot' with.
The remote machine is called general-dev.  The local machine keeps
whatever tree is current, so this nests inside
`herdr-session-with-snapshot'."
  (declare (indent 1) (debug t))
  `(let ((herdr-machines-tests--remote
          (json-parse-string (json-serialize ,snapshot)
                             :false-object nil :null-object nil)))
     (cl-letf (((symbol-function 'herdr-machines-list)
                (lambda ()
                  (list (list :id "local" :label "Local" :status 'online
                              :snapshot herdr-session--snapshot)
                        (list :id "general-dev" :label "general-dev"
                              :status 'online
                              :snapshot herdr-machines-tests--remote)))))
       ,@body)))

(ert-deftest herdr-machines-target:names-the-remote-machine ()
  "A remote target carries what a connection needs and not the tree.
A panel keeps the target as its row's section value, and a tree that
is replaced on every probe would make the row a new one each time."
  (should (equal (herdr-machines-target
                  (list :id "general-dev" :label "general-dev"
                        :status 'online :snapshot 'tree)
                  "w3:p2")
                 '(:machine (:id "general-dev" :label "general-dev"
                             :status online)
                   :pane "w3:p2"))))

(defvar herdr-term--pane)
(defvar herdr-term--connection)

(ert-deftest herdr-machines-rows:marks-the-current-row-on-its-own-machine ()
  "A pane identifier names a pane only on its own server.
With a remote terminal on screen, the remote row is the current one,
and the local row of the same identifier is not even open."
  (herdr-session-with-snapshot
      (list :agents (vector (list :pane_id "w3:p2" :agent_status "idle")))
    (herdr-machines-tests-with-remote
        (list :agents (vector (list :pane_id "w3:p2" :agent_status "idle")))
      (let ((terminal (generate-new-buffer " *herdr-machines-terminal*")))
        (unwind-protect
            (save-window-excursion
              (with-current-buffer terminal
                (setq-local herdr-term--pane "w3:p2")
                (setq-local herdr-term--connection '(:id "general-dev")))
              (set-window-buffer (selected-window) terminal)
              (should (equal
                       (mapcar (lambda (row) (plist-get (cdr row) :emphasis))
                               (herdr-machines-rows
                                #'herdr-session-agents
                                (lambda (node _current)
                                  (list :status (herdr-session-status node)
                                        :emphasis 'current
                                        :label (gethash "pane_id" node)))))
                       '(closed current))))
          (kill-buffer terminal))))))

(ert-deftest herdr-machines-visit:opens-a-remote-pane-through-its-connection ()
  "A remote target reaches the shared opener with its machine's connection.
A plist naming the local machine, which the every-pane prompt makes
for local panes too, opens with no connection."
  (let (opened)
    (cl-letf (((symbol-function 'herdr-machines-connection)
               (lambda (machine)
                 (unless (equal (plist-get machine :id) "local")
                   (list :id (plist-get machine :id)))))
              ((symbol-function 'herdr-panel-open-pane)
               (lambda (&rest arguments) (push arguments opened))))
      (herdr-machines-visit '(:machine (:id "general-dev") :pane "w3:p2")
                            'control)
      (herdr-machines-visit '(:machine (:id "local") :pane "w1:p1") 'observe)
      (herdr-machines-visit "w1:p2" 'observe)
      (should (equal (nreverse opened)
                     '(("w3:p2" control (:id "general-dev"))
                       ("w1:p1" observe nil)
                       ("w1:p2" observe)))))))

(provide 'herdr-machines-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-machines-tests.el ends here
