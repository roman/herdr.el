;;; herdr-api-tests.el --- Tests for herdr-api  -*- lexical-binding:t -*-

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

;; These drive the client against a herdr server played by Emacs itself,
;; over a real Unix socket, so the connect, send, read and close path is
;; exercised rather than stubbed.  The stand-in reproduces the three
;; behaviours of the real server that the client is built around: it
;; answers one request per connection and then closes, it rejects a
;; request that omits `params', and it holds the connection open for
;; `events.subscribe'.

;;; Code:

(require 'cl-lib)
(require 'ert)

(require 'herdr-api)

;;; Fixtures

(defvar herdr-api-test-requests nil
  "Decoded requests the stand-in server received, most recent first.")

(defvar herdr-api-test-connections nil
  "Connections the stand-in server accepted, most recent first.
A test drops one of these to play a server going away.")

(defvar herdr-api-test-reply #'ignore
  "Function returning the reply line for a decoded request.
It is called with the request hash-table.  Returning nil answers
nothing, which is how a hung or silent server is played.")

(defun herdr-api-test--send (connection string)
  "Write STRING to CONNECTION, tolerating a client that already left.
A real server survives that; here it would raise SIGPIPE and take the
whole batch run down with it."
  (when (process-live-p connection)
    (ignore-errors (process-send-string connection string))))

(defun herdr-api-test--serve (connection line)
  "Answer LINE on CONNECTION the way the herdr server would."
  (let ((request (herdr-api--parse line)))
    (push request herdr-api-test-requests)
    (cl-pushnew connection herdr-api-test-connections)
    (cond
     ((not (and (hash-table-p request) (gethash "params" request)))
      (herdr-api-test--send
       connection
       (concat (json-serialize
                '(:id "" :error (:code "invalid_request"
                                 :message "missing field `params'")))
               "\n"))
      (delete-process connection))
     (t
      (when-let* ((reply (funcall herdr-api-test-reply request)))
        (herdr-api-test--send connection reply))
      ;; Every method but `events.subscribe' spends its connection.
      (unless (equal (gethash "method" request) "events.subscribe")
        (delete-process connection))))))

(defmacro herdr-api-with-test-server (reply &rest body)
  "Evaluate BODY against a stand-in herdr server answering with REPLY.
REPLY is a function of one argument, the decoded request, returning the
line to answer with, or nil to answer nothing.  BODY can read
`herdr-api-test-requests' and can reach the server through the ordinary
entry points, because `herdr-api-socket' points at it.

The socket directory of a test that fails is kept, for inspection."
  (declare (indent 1) (debug t))
  (let ((directory (make-symbol "directory"))
        (server (make-symbol "server")))
    `(let* ((,directory (file-name-as-directory
                         (make-temp-file "herdr-api-test-" t)))
            (herdr-api-socket (expand-file-name "herdr.sock" ,directory))
            (herdr-api-timeout 2)
            (herdr-api-test-requests nil)
            (herdr-api-test-connections nil)
            (herdr-api-test-reply ,reply)
            (,server (make-network-process
                      :name "herdr-api-test-server"
                      :server t
                      :family 'local
                      :service herdr-api-socket
                      :coding 'utf-8-unix
                      :noquery t
                      :sentinel #'ignore
                      :filter #'herdr-api-test--serve)))
       (condition-case err
           (prog1 (progn ,@body)
             (mapc #'delete-process herdr-api-test-connections)
             (delete-process ,server)
             (delete-directory ,directory t))
         (error (message "Keeping test socket directory:\n  %s" ,directory)
                (mapc #'delete-process herdr-api-test-connections)
                (delete-process ,server)
                (signal (car err) (cdr err)))))))

(defun herdr-api-test-await (count)
  "Wait until the stand-in server has received COUNT requests.
`herdr-api-request' waits for its own reply, but a subscription does
not, so a test that inspects the request it sent must wait for it."
  (let ((deadline (+ (float-time) 2)))
    (while (and (< (length herdr-api-test-requests) count)
                (< (float-time) deadline))
      (accept-process-output nil 0.02))))

(defun herdr-api-test-ok (result)
  "Return a reply function answering every request with RESULT."
  (lambda (request)
    (concat (json-serialize (list :id (gethash "id" request)
                                  :result result))
            "\n")))

;;; Socket Discovery

(ert-deftest herdr-api-socket-path:prefers-the-option ()
  "An explicit socket wins over the environment."
  (let ((herdr-api-socket "/tmp/explicit.sock")
        (process-environment (cons "HERDR_SOCKET_PATH=/tmp/env.sock"
                                   process-environment)))
    (should (equal (herdr-api-socket-path) "/tmp/explicit.sock"))))

(ert-deftest herdr-api-socket-path:falls-back-to-the-environment ()
  "HERDR_SOCKET_PATH is how a pane herdr owns finds its own server."
  (let ((herdr-api-socket nil)
        (process-environment (cons "HERDR_SOCKET_PATH=/tmp/env.sock"
                                   process-environment)))
    (should (equal (herdr-api-socket-path) "/tmp/env.sock"))))

(ert-deftest herdr-api-socket-path:falls-back-to-xdg ()
  "With no environment to go on, the XDG configuration directory is used."
  (let ((herdr-api-socket nil)
        (process-environment (append '("HERDR_SOCKET_PATH="
                                       "XDG_CONFIG_HOME=/xdg")
                                     process-environment)))
    (should (equal (herdr-api-socket-path) "/xdg/herdr/herdr.sock"))))

(ert-deftest herdr-api-socket-path:ignores-an-empty-variable ()
  "An exported but empty variable reads as \"\", which is not a path.
Returning it would report \"No herdr socket at \" and hide the real
default."
  (let ((herdr-api-socket nil)
        (process-environment (append '("HERDR_SOCKET_PATH="
                                       "XDG_CONFIG_HOME=")
                                     process-environment)))
    (should (equal (herdr-api-socket-path)
                   (expand-file-name "~/.config/herdr/herdr.sock")))))

;;; Requests

(ert-deftest herdr-api-request:returns-the-result ()
  "A successful call yields the result object, unwrapped."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type "pong" :protocol 18))
    (let ((result (herdr-api-request "ping")))
      (should (equal (gethash "type" result) "pong"))
      (should (equal (gethash "protocol" result) 18)))))

(ert-deftest herdr-api-request:always-sends-params ()
  "The server rejects a request with no `params', even for `ping'."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type "pong"))
    (herdr-api-request "ping")
    (let ((request (car herdr-api-test-requests)))
      (should (equal (gethash "method" request) "ping"))
      (should (hash-table-p (gethash "params" request)))
      (should (eql (hash-table-count (gethash "params" request)) 0)))))

(ert-deftest herdr-api-request:passes-params-through ()
  "A plist becomes the request's `params' object."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type "ok"))
    (herdr-api-request "workspace.create" '(:cwd "/tmp" :focus t))
    (let ((params (gethash "params" (car herdr-api-test-requests))))
      (should (equal (gethash "cwd" params) "/tmp"))
      (should (eq (gethash "focus" params) t)))))

(ert-deftest herdr-api-request:identifiers-are-unique ()
  "Two requests do not share an identifier."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type "ok"))
    (herdr-api-request "ping")
    (herdr-api-request "ping")
    (let ((ids (mapcar (lambda (r) (gethash "id" r))
                       herdr-api-test-requests)))
      (should (eql (length ids) 2))
      (should-not (equal (car ids) (cadr ids))))))

(ert-deftest herdr-api-request:signals-a-server-error ()
  "An error reply is raised, carrying the server's own message."
  (herdr-api-with-test-server
      (lambda (request)
        (concat (json-serialize
                 (list :id (gethash "id" request)
                       :error '(:code "not_found" :message "no such pane")))
                "\n"))
    (let ((error-data
           (should-error (herdr-api-request "pane.read")
                         :type 'herdr-api-error)))
      (should (string-match-p "no such pane" (cadr error-data)))
      (should (string-match-p "not_found" (cadr error-data))))))

(ert-deftest herdr-api-request:signals-on-invalid-json ()
  "A reply that is not JSON is reported as such, not silently dropped."
  (herdr-api-with-test-server (lambda (_request) "this is not json\n")
    (should-error (herdr-api-request "ping") :type 'herdr-api-error)))

(ert-deftest herdr-api-request:signals-when-nothing-answers ()
  "A server that closes without answering is reported, not waited on."
  (herdr-api-with-test-server #'ignore
    (should-error (herdr-api-request "ping") :type 'herdr-api-error)))

(ert-deftest herdr-api-request:signals-without-a-socket ()
  "A stopped server has no socket, and that is worth saying plainly."
  (let ((herdr-api-socket "/nonexistent/herdr.sock"))
    (let ((error-data (should-error (herdr-api-request "ping")
                                    :type 'herdr-api-error)))
      (should (string-match-p "server running" (cadr error-data))))))

(ert-deftest herdr-api-request:spends-one-connection-each ()
  "Each request opens its own connection, because the server closes it."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type "ok"))
    (should (gethash "type" (herdr-api-request "ping")))
    (should (gethash "type" (herdr-api-request "ping")))
    (should (gethash "type" (herdr-api-request "ping")))
    (should (eql (length herdr-api-test-requests) 3))))

;;; Events

(ert-deftest herdr-api-subscribe:sends-tagged-subscriptions ()
  "Subscriptions travel as objects, which is what the server accepts."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type
                                                   "subscription_started"))
    (let ((process (herdr-api-subscribe '("pane.updated" "pane.created")
                                        #'ignore)))
      (unwind-protect
          (let* ((_ (herdr-api-test-await 1))
                 (subscriptions
                  (gethash "subscriptions"
                           (gethash "params" (car herdr-api-test-requests)))))
            (should (equal (seq-map (lambda (s) (gethash "type" s))
                                    subscriptions)
                           '("pane.updated" "pane.created"))))
        (herdr-api-unsubscribe process)))))

(ert-deftest herdr-api-subscribe:delivers-events-not-the-ack ()
  "The acknowledgement shares the connection but is not an event."
  (herdr-api-with-test-server
      (lambda (request)
        (concat (json-serialize (list :id (gethash "id" request)
                                      :result '(:type
                                                "subscription_started")))
                "\n"
                (json-serialize '(:event "pane_updated"
                                  :data (:pane (:pane_id "w1:p1"))))
                "\n"))
    (let* ((events nil)
           (process (herdr-api-subscribe
                     '("pane.updated")
                     (lambda (event) (push event events)))))
      (unwind-protect
          (progn
            (dotimes (_ 20)
              (unless events (accept-process-output process 0.1)))
            (should (eql (length events) 1))
            (should (equal (gethash "event" (car events)) "pane_updated")))
        (herdr-api-unsubscribe process)))))

(ert-deftest herdr-api-subscribe:reassembles-split-events ()
  "An event split across two writes is delivered once, whole."
  (herdr-api-with-test-server #'ignore
    (let* ((events nil)
           (process (herdr-api-subscribe
                     '("pane.updated")
                     (lambda (event) (push event events))))
           (line (json-serialize '(:event "pane_closed"
                                   :data (:pane_id "w1:p1")))))
      (unwind-protect
          (progn
            (herdr-api--event-filter process (substring line 0 12))
            (should (null events))
            (herdr-api--event-filter process
                                     (concat (substring line 12) "\n"))
            (should (eql (length events) 1))
            (should (equal (gethash "event" (car events)) "pane_closed")))
        (herdr-api-unsubscribe process)))))

(ert-deftest herdr-api-subscribe:reports-a-refusal ()
  "A refused subscription is news, not a line to drop as \"not an event\".
Dropping it leaves the caller waiting on a stream that will never
carry one."
  (herdr-api-with-test-server
      (lambda (request)
        (concat (json-serialize
                 (list :id (gethash "id" request)
                       :error '(:code "invalid_request"
                                :message "unknown subscription")))
                "\n"))
    (let* ((closed nil)
           (process (herdr-api-subscribe '("nope.nope") #'ignore
                                         (lambda (reason)
                                           (setq closed reason)))))
      (unwind-protect
          (progn
            (dotimes (_ 20)
              (unless closed (accept-process-output process 0.1)))
            (should (stringp closed))
            (should (string-match-p "refused" closed))
            (should (string-match-p "unknown subscription" closed))
            (should-not (process-live-p process)))
        (herdr-api-unsubscribe process)))))

(ert-deftest herdr-api-subscribe:reports-a-dropped-connection ()
  "A server that goes away must not look like a quiet one."
  (herdr-api-with-test-server
      (lambda (request)
        (concat (json-serialize (list :id (gethash "id" request)
                                      :result '(:type
                                                "subscription_started")))
                "\n"))
    (let* ((closed nil)
           (process (herdr-api-subscribe '("pane.updated") #'ignore
                                         (lambda (reason)
                                           (setq closed reason)))))
      (herdr-api-test-await 1)
      (should (process-live-p process))
      ;; Play the server going away under a subscription it accepted.
      (mapc #'delete-process herdr-api-test-connections)
      (dotimes (_ 20)
        (unless closed (accept-process-output nil 0.1)))
      (should (stringp closed))
      (should-not (process-live-p process)))))

(ert-deftest herdr-api-unsubscribe:stays-quiet ()
  "Stopping on purpose is not news, and tolerates being done twice."
  (herdr-api-with-test-server (herdr-api-test-ok '(:type
                                                   "subscription_started"))
    (let* ((closed nil)
           (process (herdr-api-subscribe '("pane.updated") #'ignore
                                         (lambda (reason)
                                           (setq closed reason)))))
      ;; Let the subscription establish, so this stops a live one rather
      ;; than racing the acknowledgement.
      (herdr-api-test-await 1)
      (accept-process-output process 0.2)
      (herdr-api-unsubscribe process)
      (herdr-api-unsubscribe process)
      (herdr-api-unsubscribe nil)
      (accept-process-output nil 0.1)
      (should (null closed)))))

(ert-deftest herdr-api-subscribe:keeps-order-under-re-entry ()
  "A blocking callback must not let later events overtake earlier ones.
Blocking runs other process filters, so this filter can be entered
again on newer data while an earlier batch is still being delivered.
Delivering straight from the filter would send the newer batch first."
  (herdr-api-with-test-server #'ignore
    (let (seen process)
      (setq process
            (herdr-api-subscribe
             '("pane.updated")
             (lambda (event)
               (let ((name (gethash "event" event)))
                 (push name seen)
                 ;; Stand in for the re-entry that blocking would cause.
                 (when (equal name "first")
                   (herdr-api--event-filter
                    process
                    (concat (json-serialize '(:event "third" :data nil))
                            "\n")))))))
      (unwind-protect
          (progn
            (herdr-api--event-filter
             process
             (concat (json-serialize '(:event "first" :data nil)) "\n"
                     (json-serialize '(:event "second" :data nil)) "\n"))
            (should (equal (reverse seen) '("first" "second" "third"))))
        (herdr-api-unsubscribe process)))))

(ert-deftest herdr-api-subscribe:survives-a-failing-callback ()
  "One bad event must not cost the caller every event behind it."
  (herdr-api-with-test-server #'ignore
    (let* ((seen nil)
           (process (herdr-api-subscribe
                     '("pane.updated")
                     (lambda (event)
                       (let ((name (gethash "event" event)))
                         (push name seen)
                         (when (equal name "bad") (error "Callback failed")))))))
      (unwind-protect
          (progn
            (herdr-api--event-filter
             process
             (concat (json-serialize '(:event "bad" :data nil)) "\n"
                     (json-serialize '(:event "good" :data nil)) "\n"))
            (should (equal (reverse seen) '("bad" "good"))))
        (herdr-api-unsubscribe process)))))

;;; _
(provide 'herdr-api-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-api-tests.el ends here
