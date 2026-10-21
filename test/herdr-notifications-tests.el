;;; herdr-notifications-tests.el --- Notices tests  -*- lexical-binding:t -*-

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

;; Drive notification delivery through the API's fake Unix socket server.

;;; Code:

(require 'herdr-api-tests)
(require 'herdr-session)
(require 'herdr-notifications)
(require 'herdr-sound)

;;; Fixtures
(defun herdr-notifications-test--event (sequence sound)
  "Return an event line with SEQUENCE and SOUND."
  (concat (json-serialize
           (list :event "notification_shown"
                 :data (list :title "Build finished" :body "All tests pass"
                             :sound sound :sequence sequence)))
          "\n"))

(defun herdr-notifications-test--wait (predicate)
  "Wait briefly for PREDICATE to become non-nil."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01)))
  (should (funcall predicate)))

(defmacro herdr-notifications-with-stream (reply &rest body)
  "Evaluate BODY with an isolated notification stream answering REPLY."
  (declare (indent 1) (debug t))
  `(herdr-api-with-test-server ,reply
     (let ((herdr-notifications-enabled t)
           (herdr-notifications-backend 'message)
           (herdr-notifications--subscription nil)
           (herdr-notifications--server nil)
           (herdr-notifications--sequence nil)
           (herdr-notifications--generation 0)
           (herdr-notifications--rejection-logged nil))
       (unwind-protect
           (progn ,@body)
         (herdr-notifications-stop)))))

;;; Delivery
(ert-deftest herdr-notifications:desktop-delivery ()
  "Desktop notifications suppress native sound and reuse Herdr sound."
  (herdr-notifications-with-stream
      (lambda (_) (herdr-notifications-test--event 1 "done"))
    (let ((herdr-notifications-backend 'auto)
          notification sounds)
      (cl-letf (((symbol-function 'notifications-get-server-information)
                 (lambda () '("test" "test" "1" "1.2")))
                ((symbol-function 'notifications-notify)
                 (lambda (&rest arguments) (setq notification arguments)))
                ((symbol-function 'herdr-sound--play)
                 (lambda (sound) (push sound sounds)))
                ((symbol-function 'message)
                 (lambda (&rest _) (ert-fail "Unexpected fallback"))))
        (herdr-notifications-start)
        (herdr-notifications-test--wait (lambda () notification))
        (should (equal (plist-get notification :title) "Build finished"))
        (should (equal (plist-get notification :body) "All tests pass"))
        (should (plist-get notification :suppress-sound))
        (should (equal sounds '(done)))))))

(ert-deftest herdr-notifications:desktop-fallback ()
  "Missing D-Bus and failed delivery both fall back to the echo area."
  (dolist (failure '(discovery delivery))
    (herdr-notifications-with-stream
        (lambda (_) (herdr-notifications-test--event 1 "none"))
      (let ((herdr-notifications-backend 'notifications)
            rendered)
        (cl-letf (((symbol-function 'notifications-get-server-information)
                   (lambda ()
                     (if (eq failure 'discovery)
                         (error "No D-Bus")
                       '("test"))))
                  ((symbol-function 'notifications-notify)
                   (lambda (&rest _) (error "Delivery failed")))
                  ((symbol-function 'herdr-sound--play)
                   (lambda (&rest _) (ert-fail "Unexpected sound")))
                  ((symbol-function 'message)
                   (lambda (format-string &rest arguments)
                     (push (apply #'format format-string arguments)
                           rendered))))
          (herdr-notifications-start)
          (herdr-notifications-test--wait (lambda () rendered))
          (should (equal rendered '("Build finished: All tests pass"))))))))

(ert-deftest herdr-notifications:restarted-server-resets-sequence ()
  "A recreated server socket accepts a new sequence starting at one."
  (let ((sequence 99))
    (herdr-notifications-with-stream
        (lambda (_) (herdr-notifications-test--event sequence "none"))
      (let ((deliveries 0)
            replacement)
        (cl-letf (((symbol-function 'message)
                   (lambda (&rest _) (cl-incf deliveries))))
          (unwind-protect
              (progn
                (herdr-notifications-start)
                (herdr-notifications-test--wait
                 (lambda () (= deliveries 1)))
                (herdr-notifications-stop)
                (delete-file herdr-api-socket)
                (setq sequence 1
                      replacement
                      (make-network-process
                       :name "herdr-restarted-test-server"
                       :server t :family 'local
                       :service herdr-api-socket :coding 'utf-8-unix
                       :noquery t :sentinel #'ignore
                       :filter #'herdr-api-test--serve))
                (herdr-notifications-start)
                (herdr-notifications-test--wait
                 (lambda () (= deliveries 2)))
                (should (= herdr-notifications--sequence 1)))
            (when replacement (delete-process replacement))))))))

(ert-deftest herdr-notifications:sound-disabled ()
  "The shared sound switch also silences explicit custom sounds."
  (herdr-notifications-with-stream
      (lambda (_) (herdr-notifications-test--event 1 "request"))
    (let ((herdr-sound-enabled nil)
          rendered)
      (cl-letf (((symbol-function 'herdr-sound--play)
                 (lambda (&rest _) (ert-fail "Unexpected sound")))
                ((symbol-function 'message)
                 (lambda (&rest _) (setq rendered t))))
        (herdr-notifications-start)
        (herdr-notifications-test--wait (lambda () rendered))))))

(ert-deftest herdr-notifications:stop-cancels-queued-delivery ()
  "A stopped session must not display already queued events."
  (herdr-notifications-with-stream #'ignore
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (ert-fail "Unexpected delivery"))))
      (herdr-notifications--receive
       (json-parse-string (herdr-notifications-test--event 1 "none")))
      (herdr-notifications-stop)
      (accept-process-output nil 0.05))))

(ert-deftest herdr-notifications:receives-and-renders ()
  "A real stream delivers the title, body and requested sound once."
  (herdr-notifications-with-stream
      (lambda (_) (herdr-notifications-test--event 12 "request"))
    (let (rendered sounds)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (push (apply #'format format-string arguments)
                         rendered)))
                ((symbol-function 'herdr-sound--play)
                 (lambda (sound) (push sound sounds))))
        (herdr-notifications-start)
        (herdr-notifications-test--wait (lambda () rendered))
        (should (equal rendered '("Build finished: All tests pass")))
        (should (equal sounds '(request)))
        (let* ((request (car herdr-api-test-requests))
               (params (gethash "params" request))
               (subscriptions (gethash "subscriptions" params)))
          (should (equal (gethash "type" (aref subscriptions 0))
                         "notification.shown")))))))

(ert-deftest herdr-notifications:ignores-duplicates-after-reconnect ()
  "Reconnecting keeps the sequence watermark for the same server."
  (herdr-notifications-with-stream
      (lambda (_)
        (concat (herdr-notifications-test--event 12 "none")
                (herdr-notifications-test--event 12 "none")))
    (let ((deliveries 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (cl-incf deliveries))))
        (herdr-notifications-start)
        (herdr-notifications-test--wait (lambda () (= deliveries 1)))
        (herdr-notifications-start)
        (herdr-api-test-await 2)
        (accept-process-output nil 0.05)
        (should (= deliveries 1))
        (herdr-api-test--send
         (car herdr-api-test-connections)
         (herdr-notifications-test--event 13 "none"))
        (herdr-notifications-test--wait (lambda () (= deliveries 2)))))))

(ert-deftest herdr-notifications:off ()
  "Disabling notifications prevents subscriptions and queued delivery."
  (herdr-notifications-with-stream #'ignore
    (let ((herdr-notifications-enabled nil))
      (herdr-notifications-start)
      (should-not herdr-notifications--subscription)
      (should-not herdr-api-test-requests)
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (ert-fail "Unexpected delivery"))))
        (herdr-notifications--receive
         (json-parse-string
          (herdr-notifications-test--event 1 "request")))))))

(ert-deftest herdr-notifications:rejection-leaves-session-running ()
  "An old server rejects notifications without losing tree events."
  (herdr-notifications-with-stream
      (lambda (request)
        (if (equal (gethash "type"
                            (aref (gethash "subscriptions"
                                           (gethash "params" request)) 0))
                   "notification.shown")
            (concat "{\"error\":{\"code\":\"invalid_params\","
                    "\"message\":\"unknown variant\"}}\n")
          "{\"result\":{\"type\":\"subscription_started\"}}\n"))
    (let ((herdr-session-poll-interval nil)
          (herdr-session--subscription nil)
          logs)
      (cl-letf (((symbol-function 'herdr-session-refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (&rest _)
                   (should inhibit-message)
                   (push 'log logs))))
        (unwind-protect
            (progn
              (herdr-session-start)
              (herdr-notifications-test--wait (lambda () logs))
              (should (herdr-session-live-p))
              (should-not herdr-notifications--subscription)
              (herdr-session-start)
              (herdr-api-test-await 4)
              (accept-process-output nil 0.05)
              (should (= (length logs) 1)))
          (herdr-session-stop))))))

;;; _
(provide 'herdr-notifications-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-notifications-tests.el ends here
