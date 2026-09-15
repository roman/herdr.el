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
It is called with the request hash-table.  Return
`herdr-api-test-hold' to keep the connection open without answering.")

(defconst herdr-api-test-hold 'herdr-api-test-hold
  "Reply value that keeps a test connection open without answering.")

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
      (let ((reply (funcall herdr-api-test-reply request)))
        (unless (eq reply herdr-api-test-hold)
          (when reply
            (herdr-api-test--send connection reply))
          ;; Every method but `events.subscribe' spends its connection.
          (unless (equal (gethash "method" request) "events.subscribe")
            (delete-process connection))))))))

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

(ert-deftest herdr-api-request-async:returns-before-a-timeout ()
  "A silent server must not block the Emacs event loop."
  (herdr-api-with-test-server
      (lambda (_request) herdr-api-test-hold)
    (let ((herdr-api-timeout 1)
          (failure nil)
          process)
      (setq process
            (with-timeout (0.5 (ert-fail "The request blocked Emacs"))
              (herdr-api-request-async
               "session.snapshot" nil #'ignore
               (lambda (condition _process)
                 (setq failure condition)))))
      (unwind-protect
          (progn
            (dotimes (_ 100)
              (unless failure
                (accept-process-output nil 0.02)))
            (should (eq (car failure) 'herdr-api-unavailable))
            (should-not (process-live-p process)))
        (when (process-live-p process)
          (delete-process process))))))

(ert-deftest herdr-api-request-async:delivers-a-result ()
  "A complete asynchronous reply reaches its success callback."
  (herdr-api-with-test-server
      (herdr-api-test-ok '(:type "pong"))
    (let (answer)
      (herdr-api-request-async
       "ping" nil
       (lambda (result _process)
         (setq answer result))
       #'ignore)
      (dotimes (_ 20)
        (unless answer
          (accept-process-output nil 0.02)))
      (should (equal (gethash "type" answer) "pong")))))

(ert-deftest herdr-api-request-async:delivers-after-the-filter-returns ()
  "A reply callback must not run inside the process filter."
  (herdr-api-with-test-server
      (herdr-api-test-ok '(:type "pong"))
    (let ((original-filter
           (symbol-function 'herdr-api--async-reply-filter))
          (inside-filter nil)
          callback-inside-filter
          delivered)
      (cl-letf (((symbol-function 'herdr-api--async-reply-filter)
                 (lambda (process chunk)
                   (setq inside-filter t)
                   (unwind-protect
                       (funcall original-filter process chunk)
                     (setq inside-filter nil)))))
        (herdr-api-request-async
         "ping" nil
         (lambda (_result _process)
           (setq callback-inside-filter inside-filter
                 delivered t))
         #'ignore)
        (dotimes (_ 20)
          (unless delivered
            (accept-process-output nil 0.02))))
      (should delivered)
      (should-not callback-inside-filter))))

(ert-deftest herdr-api-request-async:delivers-a-rejection ()
  "An asynchronous rejection reaches only the error callback."
  (herdr-api-with-test-server
      (lambda (request)
        (concat
         (json-serialize
          (list :id (gethash "id" request)
                :error (list :code "denied" :message "not allowed")))
         "\n"))
    (let ((errors 0)
          (successes 0)
          condition)
      (herdr-api-request-async
       "ping" nil
       (lambda (_result _process)
         (cl-incf successes))
       (lambda (error-data _process)
         (setq condition error-data)
         (cl-incf errors)))
      (dotimes (_ 20)
        (unless condition
          (accept-process-output nil 0.02)))
      (should (eq (car condition) 'herdr-api-rejected))
      (should (eql errors 1))
      (should (zerop successes)))))

(ert-deftest herdr-api-request-async:reports-a-malformed-error ()
  "A malformed error reply must reach the error callback."
  (herdr-api-with-test-server
      (lambda (request)
        (concat
         (json-serialize (list :id (gethash "id" request) :error t))
         "\n"))
    (let (condition)
      (herdr-api-request-async
       "ping" nil #'ignore
       (lambda (error-data _process)
         (setq condition error-data)))
      (dotimes (_ 20)
        (unless condition
          (accept-process-output nil 0.02)))
      (should (eq (car condition) 'herdr-api-error)))))

(ert-deftest herdr-api-request-async:reports-an-early-close ()
  "A connection closed without a reply must reach the error callback."
  (herdr-api-with-test-server #'ignore
    (let ((errors 0)
          condition)
      (herdr-api-request-async
       "ping" nil #'ignore
       (lambda (error-data _process)
         (setq condition error-data)
         (cl-incf errors)))
      (dotimes (_ 20)
        (unless condition
          (accept-process-output nil 0.02)))
      (should (eq (car condition) 'herdr-api-unavailable))
      (should (string-match-p "closed" (cadr condition)))
      (should (eql errors 1)))))

(ert-deftest herdr-api-request-async:cleans-up-after-a-send-error ()
  "A send error must close the new connection and cancel its timeout."
  (herdr-api-with-test-server #'ignore
    (let (connection)
      (unwind-protect
          (cl-letf (((symbol-function 'process-send-string)
                     (lambda (process _string)
                       (setq connection process)
                       (error "Send failed"))))
            (should-error
             (herdr-api-request-async "ping" nil #'ignore #'ignore))
            (should-not (process-live-p connection)))
        (when (process-live-p connection)
          (delete-process connection))))))

(ert-deftest herdr-api-cancel-request:cancels-a-pending-request ()
  "Cancellation must close a pending process without callbacks."
  (herdr-api-with-test-server
      (lambda (_request) herdr-api-test-hold)
    (let* ((callbacks 0)
           (process
            (herdr-api-request-async
             "ping" nil
             (lambda (&rest _)
               (cl-incf callbacks))
             (lambda (&rest _)
               (cl-incf callbacks)))))
      (herdr-api-cancel-request process)
      (accept-process-output nil 0.01)
      (should-not (process-live-p process))
      (should (zerop callbacks)))))

(ert-deftest herdr-api-cancel-request:cancels-a-queued-callback ()
  "Cancellation must suppress a callback queued after process completion."
  (herdr-api-with-test-server
      (lambda (_request) herdr-api-test-hold)
    (let ((called nil)
          process)
      (setq process
            (herdr-api-request-async
             "ping" nil
             (lambda (_result _process)
               (setq called t))
             #'ignore))
      (herdr-api--complete-async-request
       process
       (json-serialize
        (list :id (process-get process 'herdr-api-id)
              :result (list :type "pong"))))
      (herdr-api-cancel-request process)
      (accept-process-output nil 0.01)
      (should-not called))))

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

;;; Traffic

(defmacro herdr-api-with-fresh-traffic (&rest body)
  "Run BODY with the traffic counts empty and restore them afterwards.
The counts are global and accumulate for as long as Emacs runs, so a
test that read them unbound would depend on which tests ran first."
  (declare (indent 0) (debug t))
  `(let ((herdr-api--traffic (make-hash-table :test #'equal))
         (herdr-api--traffic-slowest (make-hash-table :test #'equal))
         (herdr-api--traffic-blocked 0)
         (herdr-api--traffic-events 0)
         (herdr-api--traffic-baseline nil)
         (herdr-api--traffic-since (float-time)))
     ,@body))

(ert-deftest herdr-api-request:counts-each-method ()
  "Every call is counted under its own method name."
  (herdr-api-with-fresh-traffic
    (herdr-api-with-test-server (herdr-api-test-ok '(:type "pong"))
      (herdr-api-request "ping")
      (herdr-api-request "ping")
      (herdr-api-request "session.snapshot")
      (should (equal (car (gethash "ping" herdr-api--traffic)) 2))
      (should (equal (car (gethash "session.snapshot" herdr-api--traffic))
                     1)))))

(ert-deftest herdr-api-request:counts-a-call-that-failed ()
  "A request that never reached the server is the slowest kind there is.
Counting only the successes would report a stalled session as quiet."
  (herdr-api-with-fresh-traffic
    (let ((herdr-api-socket "/nonexistent/herdr.sock"))
      (should-error (herdr-api-request "ping") :type 'herdr-api-unavailable))
    (should (equal (car (gethash "ping" herdr-api--traffic)) 1))))

(ert-deftest herdr-api-request-async:counts-a-failed-connection ()
  "An asynchronous connection failure must still count as one request."
  (herdr-api-with-fresh-traffic
    (let ((herdr-api-socket "/nonexistent/herdr.sock"))
      (should-error
       (herdr-api-request-async "ping" nil #'ignore #'ignore)
       :type 'herdr-api-unavailable))
    (should (equal (gethash "ping" herdr-api--traffic) '(1 0)))))

(ert-deftest herdr-api-request:records-no-more-than-it-waited ()
  "A recorded wait longer than the wall clock it happened in is wrong."
  (herdr-api-with-fresh-traffic
    (herdr-api-with-test-server (herdr-api-test-ok '(:type "pong"))
      (let ((before (float-time)))
        (herdr-api-request "ping")
        (should (<= (nth 1 (gethash "ping" herdr-api--traffic))
                    (- (float-time) before)))))))

(ert-deftest herdr-api--note-request:counts-a-nested-wait-once ()
  "Waiting runs timers, so a refresh can begin inside an outer wait.
Adding both spans to the total would report more waiting than the
window holding it, which is the one figure a reader checks first."
  (herdr-api-with-fresh-traffic
    (let ((start (- (float-time) 0.2)))
      (let ((herdr-api--traffic-depth 2))
        (herdr-api--note-request "inner" start))
      (let ((herdr-api--traffic-depth 1))
        (herdr-api--note-request "outer" start)))
    ;; Between one span of 0.2 and the two the bug would add, clear of
    ;; both: `float-time' rounds, so 0.2 can come back a shade under.
    (should (> herdr-api--traffic-blocked 0.15))
    (should (< herdr-api--traffic-blocked 0.3))))

(ert-deftest herdr-api--note-request:keeps-the-slowest-wait ()
  "One request that timed out is the symptom, and a mean hides it."
  (herdr-api-with-fresh-traffic
    (herdr-api--note-request "ping" (- (float-time) 0.3))
    (herdr-api--note-request "ping" (float-time))
    ;; Well clear of both spans rather than exactly on one: `float-time'
    ;; rounds, so the recorded 0.3 can come back a shade under it.
    (should (> (gethash "ping" herdr-api--traffic-slowest) 0.25))))

(ert-deftest herdr-api--note-request:does-not-count-async-latency-as-wait ()
  "Asynchronous latency must count as a request without blocked time."
  (herdr-api-with-fresh-traffic
    (herdr-api--note-request "ping" (- (float-time) 1) 'asynchronous)
    (should (equal (gethash "ping" herdr-api--traffic) '(1 0)))
    (should-not (gethash "ping" herdr-api--traffic-slowest))
    (should (zerop herdr-api--traffic-blocked))))

(ert-deftest herdr-api-subscribe:counts-events-not-the-ack ()
  "Only events are counted, so the count can be read against requests."
  (herdr-api-with-fresh-traffic
    (herdr-api-with-test-server #'ignore
      (let ((process (herdr-api-subscribe '("pane.updated") #'ignore)))
        (unwind-protect
            (progn
              (herdr-api--event-filter
               process
               (concat (json-serialize '(:id "emacs-1" :result nil)) "\n"
                       (json-serialize '(:event "pane_updated" :data nil))
                       "\n"
                       (json-serialize '(:event "pane_updated" :data nil))
                       "\n"))
              (should (equal herdr-api--traffic-events 2)))
          (herdr-api-unsubscribe process))))))

(ert-deftest herdr-api--traffic-rows:orders-by-count ()
  "The busiest method is the one a reader needs first."
  (herdr-api-with-fresh-traffic
    (herdr-api--note-request "quiet" (float-time))
    (herdr-api--note-request "busy" (float-time))
    (herdr-api--note-request "busy" (float-time))
    (should (equal (mapcar #'car (herdr-api--traffic-rows))
                   '("busy" "quiet")))))

(ert-deftest herdr-api-reset-traffic:empties-the-report ()
  "A measurement of one stretch needs the earlier ones left out of it."
  (herdr-api-with-fresh-traffic
    (let ((herdr-api--traffic-depth 1))
      (herdr-api--note-request "ping" (float-time)))
    (herdr-api--note-event)
    (herdr-api-reset-traffic)
    (should (null (herdr-api--traffic-rows)))))

(ert-deftest herdr-api-reset-traffic:keeps-the-counts-rising ()
  "A metrics reader needs counters that only ever go up.
Clearing them on reset would read to a scraper as a restarted process
and throw away every rate spanning the reset."
  (herdr-api-with-fresh-traffic
    (let ((herdr-api--traffic-depth 1))
      (herdr-api--note-request "ping" (float-time)))
    (herdr-api--note-event)
    (herdr-api-reset-traffic)
    (let ((traffic (herdr-api-traffic)))
      (should (equal (plist-get traffic :events) 1))
      (should (equal (plist-get (cdr (assoc "ping"
                                            (plist-get traffic :requests)))
                                :count)
                     1)))))

(ert-deftest herdr-api--traffic-rows:counts-only-the-window ()
  "What the report shows is the counts less the baseline reset took."
  (herdr-api-with-fresh-traffic
    (herdr-api--note-request "ping" (float-time))
    (herdr-api--note-request "ping" (float-time))
    (herdr-api-reset-traffic)
    (herdr-api--note-request "ping" (float-time))
    (let ((rows (herdr-api--traffic-rows)))
      (should (equal (length rows) 1))
      (should (equal (nth 0 (car rows)) "ping"))
      (should (equal (nth 1 (car rows)) 1)))))

(ert-deftest herdr-api-traffic:reports-the-slowest-of-the-window ()
  "The slowest wait belongs to its window, not to the whole run.
It is a gauge rather than a counter, so a reset forgets it instead of
holding the all-time worst for as long as Emacs runs."
  (herdr-api-with-fresh-traffic
    (herdr-api--note-request "ping" (- (float-time) 0.3))
    (herdr-api-reset-traffic)
    (herdr-api--note-request "ping" (float-time))
    (should (< (plist-get (cdr (assoc "ping"
                                      (plist-get (herdr-api-traffic)
                                                 :requests)))
                          :slowest)
               0.3))))

(ert-deftest herdr-api-report-traffic:reports-an-untouched-server ()
  "The report has to render before anything has been counted."
  (herdr-api-with-fresh-traffic
    (herdr-api-report-traffic)
    (with-current-buffer "*herdr-api-traffic*"
      (should (string-match-p "total" (buffer-string)))
      (should (string-match-p "events received" (buffer-string))))))

;;; _
(provide 'herdr-api-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-api-tests.el ends here
