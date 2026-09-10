;;; herdr-machines.el --- Show saved herdr machines  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes tools

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

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

;; The local machine and saved SSH machines from Herdr 0.9, with the
;; connection state of each one.  The local Herdr CLI owns the saved
;; profiles.  A short asynchronous SSH status request checks each enabled
;; remote server without delaying a panel redraw.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)

(require 'herdr-panel)
(require 'herdr-session)

;;; Options

(defcustom herdr-machines-executable "herdr"
  "Herdr executable used to read the saved machine profiles."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

(defcustom herdr-machines-ssh-executable "ssh"
  "SSH executable used to check saved machines."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'string)

(defcustom herdr-machines-probe-interval 5
  "Seconds between connection checks for each enabled machine."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

(defcustom herdr-machines-probe-timeout 10
  "Seconds to wait for a saved machine probe to finish."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

(defcustom herdr-machines-selection-wait 1
  "Seconds to wait for fresh probes before offering server choices."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-panel
  :type 'number)

;;; Variables

(defvar herdr-machines--profiles nil
  "Saved machine profiles from the most recent Herdr CLI response.")

(defvar herdr-machines--statuses (make-hash-table :test #'equal)
  "Connection status symbols keyed by machine profile identifier.")

(defvar herdr-machines--probe-times (make-hash-table :test #'equal)
  "Most recent probe start time keyed by machine profile identifier.")

(defvar herdr-machines--probes (make-hash-table :test #'equal)
  "Live probe processes keyed by machine profile identifier.")

(defvar herdr-machines--snapshots (make-hash-table :test #'equal)
  "Remote session snapshots keyed by machine profile identifier.")

(defvar herdr-machines--server-sockets (make-hash-table :test #'equal)
  "Remote server socket paths keyed by machine profile identifier.")

(defvar herdr-machines--remote-executables (make-hash-table :test #'equal)
  "Remote Herdr executable paths keyed by machine profile identifier.")

(defvar herdr-machines--tunnels (make-hash-table :test #'equal)
  "SSH tunnel processes keyed by machine profile identifier.")

(defvar herdr-machines--tunnel-sockets (make-hash-table :test #'equal)
  "Local forwarding socket paths keyed by machine profile identifier.")

(defvar herdr-machines-change-hook nil
  "Hook run after a remote machine state or snapshot changes.")

(defun herdr-machines-refresh ()
  "Read saved profiles and start due machine probes."
  (let ((profiles (herdr-machines--read-profiles)))
    (herdr-machines--forget-removed-profiles profiles)
    (setq herdr-machines--profiles profiles))
  (dolist (profile herdr-machines--profiles)
    (herdr-machines--probe-if-due profile)))

;;; Profiles

(defun herdr-machines--read-profiles ()
  "Return saved machine profiles reported by the Herdr CLI."
  (with-temp-buffer
    (if (zerop (or (ignore-errors
                     (process-file herdr-machines-executable nil t nil
                                   "machine" "list" "--json"))
                   1))
        (condition-case nil
            (json-parse-string (buffer-string) :array-type 'list)
          (json-parse-error herdr-machines--profiles))
      herdr-machines--profiles)))

(defun herdr-machines--forget-removed-profiles (profiles)
  "Cancel and forget saved machines absent from PROFILES."
  (dolist (old-profile herdr-machines--profiles)
    (let ((id (gethash "id" old-profile)))
      (unless (seq-find (lambda (profile)
                          (equal id (gethash "id" profile)))
                        profiles)
        (herdr-machines--cancel-probe id)))))

;;; Probes

(defun herdr-machines--status (profile)
  "Return the connection status for machine PROFILE."
  (if (gethash "enabled" profile)
      (or (gethash (gethash "id" profile) herdr-machines--statuses)
          'connecting)
    'disabled))

(defun herdr-machines--probe-if-due (profile)
  "Start a connection probe for PROFILE when its cache has expired."
  (let* ((id (gethash "id" profile))
         (last-probe (gethash id herdr-machines--probe-times)))
    (if (not (gethash "enabled" profile))
        (herdr-machines--cancel-probe id)
      (when (and (not (process-live-p (gethash id herdr-machines--probes)))
                 (or (null last-probe)
                     (>= (- (float-time) last-probe)
                         herdr-machines-probe-interval)))
        (puthash id (float-time) herdr-machines--probe-times)
        (puthash id (herdr-machines--start-probe profile)
                 herdr-machines--probes)))))

(defun herdr-machines--cancel-probe (id)
  "Cancel the connection probe and cached state for machine ID."
  (when-let* ((process (gethash id herdr-machines--probes)))
    (process-put process 'herdr-machine-finished t)
    (when-let* ((timer (process-get process 'herdr-machine-timeout)))
      (cancel-timer timer))
    (when (process-live-p process)
      (delete-process process))
    (herdr-machines--kill-probe-buffers process))
  (remhash id herdr-machines--probes)
  (remhash id herdr-machines--probe-times)
  (remhash id herdr-machines--statuses)
  (remhash id herdr-machines--snapshots)
  (remhash id herdr-machines--server-sockets)
  (remhash id herdr-machines--remote-executables)
  (herdr-machines--stop-tunnel id))

(defun herdr-machines--remote-command (session)
  "Return the remote shell command to check SESSION."
  (format
   (concat
    "herdr_path=$(command -v herdr 2>/dev/null); "
    "if [ -z \"$herdr_path\" ]; then "
    "for candidate in \"$HOME/.local/bin/herdr\" "
    "/opt/homebrew/bin/herdr /usr/local/bin/herdr "
    "/home/linuxbrew/.linuxbrew/bin/herdr "
    "\"$HOME\"/.local/share/mise/installs/herdr/*/bin/herdr "
    "\"$HOME/.nix-profile/bin/herdr\" "
    "\"/etc/profiles/per-user/$USER/bin/herdr\" "
    "/nix/var/nix/profiles/default/bin/herdr "
    "/run/current-system/sw/bin/herdr; do "
    "if [ -x \"$candidate\" ]; then herdr_path=$candidate; break; fi; "
    "done; fi; "
    "if [ -z \"$herdr_path\" ]; then "
    "echo 'herdr executable not ready; install or update' >&2; exit 127; fi; "
    "\"$herdr_path\" --session %s status server --json && "
    "printf '\\036' && "
    "\"$herdr_path\" --session %s api snapshot && "
    "printf '\\036%%s' \"$herdr_path\"")
   (shell-quote-argument session)
   (shell-quote-argument session)))

(defun herdr-machines--start-probe (profile)
  "Start a remote server probe for PROFILE and return its process."
  (let* ((id (gethash "id" profile))
         (session (gethash "session" profile))
         (buffer (generate-new-buffer
                  (format " *herdr-machine-%s*" id)))
         (stderr-buffer (generate-new-buffer
                         (format " *herdr-machine-%s-stderr*" id)))
         (remote-command (herdr-machines--remote-command session)))
    (let ((process
           (make-process
            :name (format "herdr-machine-%s" id)
            :buffer buffer
            :stderr stderr-buffer
            :command (list herdr-machines-ssh-executable
                           "-o" "BatchMode=yes"
                           "-o" "ConnectTimeout=5"
                           (gethash "target" profile)
                           remote-command)
            :noquery t
            :sentinel #'herdr-machines--probe-finished)))
      (process-put process 'herdr-machine-id id)
      (process-put process 'herdr-machine-stderr-buffer stderr-buffer)
      (process-put process 'herdr-machine-timeout
                   (run-at-time herdr-machines-probe-timeout nil
                                #'herdr-machines--probe-timed-out
                                process))
      process)))

(defun herdr-machines--probe-finished (process _event)
  "Record the result when PROCESS finishes."
  (when (and (memq (process-status process) '(exit signal))
             (not (process-get process 'herdr-machine-finished)))
    (process-put process 'herdr-machine-finished t)
    (when-let* ((timer (process-get process 'herdr-machine-timeout)))
      (cancel-timer timer))
    (let* ((output (with-current-buffer (process-buffer process)
                     (buffer-string)))
           (stderr-buffer (process-get process 'herdr-machine-stderr-buffer))
           (error-output (if (buffer-live-p stderr-buffer)
                             (with-current-buffer stderr-buffer (buffer-string))
                           "")))
      (herdr-machines--record-probe-result
       (process-get process 'herdr-machine-id)
       (process-exit-status process)
       (if (zerop (process-exit-status process)) output error-output)))
    (herdr-machines--kill-probe-buffers process)))

(defun herdr-machines--probe-timed-out (process)
  "Stop a stalled machine probe PROCESS and record a reconnecting state."
  (when (process-live-p process)
    (process-put process 'herdr-machine-finished t)
    (delete-process process)
    (herdr-machines--record-probe-result
     (process-get process 'herdr-machine-id) 255 "connection timed out")
    (herdr-machines--kill-probe-buffers process)))

(defun herdr-machines--kill-probe-buffers (process)
  "Kill the output buffers that belong to PROCESS."
  (dolist (buffer (list (process-buffer process)
                        (process-get process 'herdr-machine-stderr-buffer)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun herdr-machines--record-probe-result (id exit-status output)
  "Record for ID the machine state in EXIT-STATUS and OUTPUT."
  (let* ((parts (split-string output "\036"))
         (status (herdr-machines--probe-status exit-status (car parts))))
    (puthash id status herdr-machines--statuses)
    (if (and (eq status 'online) (cadr parts))
        (condition-case nil
            (let* ((server (json-parse-string (car parts)))
                   (response (json-parse-string (cadr parts)))
                   (result (gethash "result" response))
                   (snapshot (and result (gethash "snapshot" result))))
              (if (and snapshot
                       (stringp (gethash "socket" server))
                       (not (string-empty-p (gethash "socket" server)))
                       (caddr parts)
                       (not (string-empty-p (string-trim (caddr parts)))))
                  (progn
                    (puthash id snapshot herdr-machines--snapshots)
                    (puthash id (gethash "socket" server)
                             herdr-machines--server-sockets)
                    (puthash id (string-trim (or (caddr parts) "herdr"))
                             herdr-machines--remote-executables))
                (error "Herdr snapshot response has no snapshot")))
          (error
           (puthash id 'attention herdr-machines--statuses)
           (remhash id herdr-machines--snapshots)))
      (remhash id herdr-machines--snapshots)
      (remhash id herdr-machines--server-sockets)
      (remhash id herdr-machines--remote-executables)))
  (remhash id herdr-machines--probes)
  (run-hooks 'herdr-machines-change-hook))

(defun herdr-machines-list ()
  "Return local and saved machines with their status and session snapshot."
  (cons (list :id "local" :label "Local"
              :status (if (herdr-session-live-p) 'online 'reconnecting)
              :snapshot herdr-session--snapshot)
        (mapcar (lambda (profile)
                  (let ((id (gethash "id" profile)))
                    (list :id id
                          :label (gethash "label" profile)
                          :status (herdr-machines--status profile)
                          :snapshot (gethash id herdr-machines--snapshots))))
                herdr-machines--profiles)))

(defun herdr-machines-online-list ()
  "Return the machines whose Herdr servers are online."
  (seq-filter (lambda (machine) (eq (plist-get machine :status) 'online))
              (herdr-machines-list)))

(defun herdr-machines-read-online ()
  "Return an online machine, prompting when more than one is available."
  (let ((machines (herdr-machines-refresh-online)))
    (pcase machines
      ('() (user-error "No Herdr servers are online"))
      (`(,machine) machine)
      (_ (let* ((choices (mapcar (lambda (machine)
                                   (cons (plist-get machine :label) machine))
                                 machines))
                (choices
                 (mapcar
                  (lambda (choice)
                    (if (> (seq-count
                            (lambda (machine)
                              (equal (plist-get machine :label) (car choice)))
                            machines)
                           1)
                        (cons (format "%s (%s)" (car choice)
                                      (plist-get (cdr choice) :id))
                              (cdr choice))
                      choice))
                  choices))
                (label (completing-read "Herdr server: " choices nil t)))
           (cdr (assoc label choices)))))))

(defun herdr-machines-refresh-online ()
  "Refresh machine states briefly and return the online machines."
  (unless (herdr-session-live-p)
    (condition-case nil
        (herdr-session-start)
      (error nil)))
  (herdr-machines-refresh)
  (let ((deadline (+ (float-time) herdr-machines-selection-wait)))
    (while (and (seq-some #'process-live-p
                          (hash-table-values herdr-machines--probes))
                (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (herdr-machines-online-list))

(defun herdr-machines-connection (machine)
  "Return a terminal connection for remote MACHINE, or nil for local."
  (let ((id (plist-get machine :id)))
    (unless (equal id "local")
      (unless (eq (plist-get machine :status) 'online)
        (user-error "Herdr server %s is offline" (plist-get machine :label)))
      (let* ((profile (seq-find (lambda (item)
                                  (equal id (gethash "id" item)))
                                herdr-machines--profiles))
             (target (and profile (gethash "target" profile)))
             (session (and profile (gethash "session" profile)))
             (socket (herdr-machines--ensure-tunnel id target)))
        (list :id id
              :label (plist-get machine :label)
              :socket socket
              :stream-command
              (list herdr-machines-ssh-executable "-o" "BatchMode=yes"
                    target
                    (format "%s --session %s"
                            (shell-quote-argument
                             (gethash id herdr-machines--remote-executables))
                            (shell-quote-argument session))))))))

(defun herdr-machines--ensure-tunnel (id target)
  "Return a local socket forwarding to machine ID at TARGET."
  (let ((process (gethash id herdr-machines--tunnels))
        (socket (gethash id herdr-machines--tunnel-sockets)))
    (unless (and (process-live-p process) socket (file-exists-p socket))
      (herdr-machines--stop-tunnel id)
      (setq socket (make-temp-name
                    (expand-file-name (format "herdr-%s-" id)
                                      temporary-file-directory)))
      (setq process
            (make-process
             :name (format "herdr-tunnel-%s" id)
             :buffer nil
             :command
             (list herdr-machines-ssh-executable "-N" "-o" "BatchMode=yes"
                   "-o" "ExitOnForwardFailure=yes"
                   "-o" "StreamLocalBindUnlink=yes"
                   "-L" (format "%s:%s" socket
                                (gethash id herdr-machines--server-sockets))
                   target)
             :noquery t))
      (puthash id process herdr-machines--tunnels)
      (puthash id socket herdr-machines--tunnel-sockets)
      (let ((deadline (+ (float-time) herdr-machines-probe-timeout)))
        (while (and (process-live-p process)
                    (not (file-exists-p socket))
                    (< (float-time) deadline))
          (accept-process-output process 0.05)))
      (unless (and (process-live-p process) (file-exists-p socket))
        (herdr-machines--stop-tunnel id)
        (user-error "Cannot connect to Herdr server %s" target)))
    socket))

(defun herdr-machines--stop-tunnel (id)
  "Stop the SSH tunnel for machine ID."
  (when-let* ((process (gethash id herdr-machines--tunnels)))
    (when (process-live-p process)
      (delete-process process)))
  (when-let* ((socket (gethash id herdr-machines--tunnel-sockets)))
    (when (file-exists-p socket)
      (delete-file socket)))
  (remhash id herdr-machines--tunnels)
  (remhash id herdr-machines--tunnel-sockets))

(defun herdr-machines--probe-status (exit-status output)
  "Return the machine status implied by EXIT-STATUS and OUTPUT."
  (cond
    ((zerop exit-status)
     (condition-case nil
         (let* ((status (json-parse-string output))
                (capabilities (gethash "capabilities" status)))
           (if (and (eq (gethash "running" status) t)
                    (eq (gethash "endpoint_compatible" status) t)
                    (eq (gethash "surface_interest" capabilities) t)
                    (eq (gethash "health_check" capabilities) t))
               'online
             'attention))
       (json-parse-error 'attention)))
    ((and (eql exit-status 255)
          (not (herdr-machines--attention-error-p output)))
     'reconnecting)
    (t 'attention)))

(defun herdr-machines--attention-error-p (output)
  "Return non-nil when SSH OUTPUT describes an error requiring action."
  (let ((message (downcase output)))
    (seq-some (lambda (needle) (string-match-p needle message))
              '("permission denied"
                "host key verification failed"
                "remote host identification has changed"
                "no matching host key"
                "not ready"
                "install or update"
                "protocol"
                "handshake"))))

;;; _
(provide 'herdr-machines)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-machines.el ends here
