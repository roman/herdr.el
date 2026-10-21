;;; herdr-notifications.el --- Show Herdr notices  -*- lexical-binding:t -*-

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

;; Display custom notification.shown events while the session is running.
;; A separate subscription lets older servers reject this event without
;; stopping the session tree.  Agent status events stay with herdr-sound;
;; the custom notification stream contains no agent status transitions.

;;; Code:

(require 'herdr-api)
(require 'notifications)
(require 'subr-x)

(declare-function herdr-sound-play "herdr-sound" (sound))

;;; Options
(defgroup herdr-notifications nil
  "Custom Herdr notifications displayed by Emacs."
  :group 'herdr-api
  :prefix "herdr-notifications-")

(defcustom herdr-notifications-enabled t
  "Whether to subscribe to and display custom Herdr notifications.
Restart `herdr-session-start' after enabling this option.  Disabling
it also suppresses delivery from an existing subscription."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-notifications
  :type 'boolean)

(defcustom herdr-notifications-backend 'auto
  "Where to display custom Herdr notifications.
`auto' uses desktop notifications when D-Bus provides a notification
server, otherwise the echo area.  `notifications' requests desktop
delivery with the same fallback.  `message' always uses the echo area."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-notifications
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Desktop notifications" notifications)
                 (const :tag "Echo area" message)))

;;; Variables
(defvar herdr-notifications--subscription nil
  "Process carrying custom notifications, or nil when stopped.")

(defvar herdr-notifications--server nil
  "Socket identity for the sequence watermark.
The value is (PATH INODE MODIFICATION-TIME).  A recreated socket
identifies a restarted server whose sequence counter starts over.")

(defvar herdr-notifications--sequence nil
  "Highest notification sequence accepted from the current server.")

(defvar herdr-notifications--generation 0
  "Generation invalidating queued delivery after a stop.")

(defvar herdr-notifications--rejection-logged nil
  "Whether a subscription rejection has already been logged.")

;;; Lifecycle
(defun herdr-notifications-start ()
  "Subscribe to custom notifications for the current session socket."
  (herdr-notifications-stop)
  (when herdr-notifications-enabled
    (let* ((socket (herdr-api-socket-path))
           (attributes (file-attributes socket))
           (server (list socket
                         (file-attribute-inode-number attributes)
                         (file-attribute-modification-time attributes))))
      (unless (equal server herdr-notifications--server)
        (setq herdr-notifications--server server
              herdr-notifications--sequence nil)))
    (setq herdr-notifications--subscription
          (herdr-api-subscribe '("notification.shown")
                               #'herdr-notifications--receive
                               #'herdr-notifications--closed))))

(defun herdr-notifications-stop ()
  "Stop custom notifications and cancel queued delivery.
Keep the watermark so reconnecting cannot replay a notification."
  (setq herdr-notifications--generation
        (1+ herdr-notifications--generation))
  (herdr-api-unsubscribe herdr-notifications--subscription)
  (setq herdr-notifications--subscription nil))

(defun herdr-notifications--closed (reason)
  "Record the stream closing for REASON.
Log a rejected subscription once, without changing the echo area."
  (setq herdr-notifications--subscription nil)
  (when (and (string-prefix-p "subscription refused:" reason)
             (not herdr-notifications--rejection-logged))
    (setq herdr-notifications--rejection-logged t)
    (let ((inhibit-message t))
      (message "herdr-notifications: %s" reason))))

;;; Delivery
(defun herdr-notifications--receive (event)
  "Queue a custom notification EVENT outside the process filter."
  (when (and herdr-notifications-enabled
             (equal (gethash "event" event) "notification_shown"))
    (let* ((data (gethash "data" event))
           (sequence (gethash "sequence" data))
           (generation herdr-notifications--generation))
      (when (and (integerp sequence)
                 (or (null herdr-notifications--sequence)
                     (> sequence herdr-notifications--sequence)))
        (setq herdr-notifications--sequence sequence)
        (run-at-time
         0 nil
         (lambda ()
           (when (and herdr-notifications-enabled
                      (= generation herdr-notifications--generation))
             (herdr-notifications--display data))))))))

(defun herdr-notifications--display (data)
  "Display notification DATA and play its requested custom sound.
Suppress desktop sound so only `herdr-sound-play' plays the sound."
  (let ((title (gethash "title" data))
        (body (gethash "body" data)))
    (unless (and (not (eq herdr-notifications-backend 'message))
                 (condition-case nil
                     (when (notifications-get-server-information)
                       (notifications-notify
                        :app-name "Herdr" :title title
                        :body (or body "") :suppress-sound t)
                       t)
                   (error nil)))
      (message "%s%s" title
               (if (and (stringp body) (not (string-empty-p body)))
                   (concat ": " body)
                 ""))))
  (when-let* ((sound (pcase (gethash "sound" data)
                       ("request" 'request)
                       ("done" 'done))))
    (require 'herdr-sound)
    (herdr-sound-play sound)))

;;; _
(provide 'herdr-notifications)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-notifications.el ends here
