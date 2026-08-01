;;; herdr-api.el --- Talk to the herdr server  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>
;; Homepage: https://github.com/roman/herdr.el
;; Keywords: processes tools

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

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

;; Transport for the herdr server's public JSON API, the socket herdr
;; documents for third-party tools.  This file carries requests and events
;; and nothing else: it knows no method names and builds no user interface,
;; so what herdr adds next needs no change here.  Live terminal output does
;; not travel this socket at all; see `herdr-term' for that.

;; The protocol is one line of JSON in each direction:
;;
;;   -> {"id":ID,"method":METHOD,"params":{...}}
;;   <- {"id":ID,"result":{...}}
;;   <- {"id":ID,"error":{"code":CODE,"message":MESSAGE}}
;;
;; Three properties of it shape this file, and each was confirmed against a
;; running server rather than taken from documentation:
;;
;; - The server answers one request per connection and then closes it.
;;   There is no reply to correlate and no connection to pool, so
;;   `herdr-api-request' opens a connection, spends it and drops it.
;;
;; - `params' is mandatory, including for a method that defines no
;;   parameter.  Omitting the key is an `invalid_request' error, so
;;   requests always carry at least an empty object.
;;
;; - `events.subscribe' is the exception that keeps its connection.  It
;;   acknowledges like any other method and then pushes event lines until
;;   the connection closes.  Its subscriptions are objects rather than
;;   names, and the events it pushes are named with underscores where the
;;   subscription used dots: subscribing to "pane.updated" delivers events
;;   whose `event' is "pane_updated".

;;; Code:

;;; Options

(defgroup herdr-api nil
  "Client for the herdr server's JSON API."
  :group 'processes
  :prefix "herdr-api-")

(defcustom herdr-api-socket nil
  "Path of the herdr API socket, or nil to discover it.
When nil, the HERDR_SOCKET_PATH environment variable is used, which
herdr exports into every pane it owns, so an Emacs started from inside
herdr reaches its own server.  Failing that, the socket is looked for
at \"herdr/herdr.sock\" under the XDG configuration directory."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-api
  :type '(choice (const :tag "Discover" nil) file))

(defcustom herdr-api-timeout 5
  "How many seconds to wait for the server to answer a request."
  :package-version '(herdr . "0.1.0")
  :group 'herdr-api
  :type 'number)

;;; Errors

;; Three conditions rather than one, because they want different
;; treatment.  A server that is not running is the user's problem and must
;; not open the debugger, so it inherits `user-error'; a reply this client
;; cannot make sense of is a fault in herdr or in this file, and hiding it
;; from the debugger costs an afternoon.  Both remain catchable as
;; `herdr-api-error'.

(define-error 'herdr-api-error "Herdr API error")

(define-error 'herdr-api-unavailable "Cannot reach the herdr server"
  '(herdr-api-error user-error))

(define-error 'herdr-api-rejected "Herdr rejected the request"
  '(herdr-api-error user-error))

;;; Variables

(defvar herdr-api--request-counter 0
  "Count of requests made, which makes each request identifier unique.")

;;; Connections

(defun herdr-api-socket-path ()
  "Return the path of the herdr API socket.
See `herdr-api-socket' for how the path is discovered."
  (or herdr-api-socket
      (herdr-api--getenv "HERDR_SOCKET_PATH")
      (expand-file-name "herdr/herdr.sock"
                        (or (herdr-api--getenv "XDG_CONFIG_HOME")
                            "~/.config"))))

(defun herdr-api--getenv (name)
  "Return environment variable NAME, or nil when it is empty.
A variable exported with no value reads as the empty string, which is
not a path and must not be mistaken for one."
  (let ((value (getenv name)))
    (and value (not (string-empty-p value)) value)))

(defun herdr-api--connect (name)
  "Open a connection to the herdr socket, named NAME.
The connection has no buffer and discards everything until its caller
installs a filter, so that nothing Emacs reports about the process can
reach a parser as though it were protocol.

Signal `herdr-api-unavailable' when there is no socket to connect to,
which is what a stopped server looks like from here."
  (let ((path (herdr-api-socket-path)))
    (unless (file-exists-p path)
      (signal 'herdr-api-unavailable
              (list (format "No herdr socket at %s; is the server running?"
                            path))))
    (condition-case err
        (make-network-process :name name
                              :family 'local
                              :service path
                              :coding 'utf-8-unix
                              :noquery t
                              :buffer nil
                              :filter #'ignore
                              :sentinel #'ignore)
      (error
       (signal 'herdr-api-unavailable
               (list (format "Cannot reach herdr at %s: %s" path
                             (error-message-string err))))))))

;;; Requests

(defun herdr-api-request (method &optional params)
  "Call METHOD on the herdr server and return the result object.
PARAMS is a plist serialized as the request's `params' object; the
server requires that object even when the method takes no parameter.

Signal `herdr-api-unavailable' when the server cannot be reached or
does not answer within `herdr-api-timeout' seconds, and
`herdr-api-rejected' when it answers with an error.

This spends one connection, because the server answers a single
request and then closes it.  It blocks until the answer arrives, and a
process filter runs with quitting inhibited, so do not call it from
one: an event callback that does will freeze Emacs until the timeout
expires, with no way to interrupt it."
  (let ((process (herdr-api--connect "herdr-api"))
        (id (herdr-api--next-id)))
    (unwind-protect
        (progn
          (process-put process 'herdr-api-pending "")
          (set-process-filter process #'herdr-api--reply-filter)
          (process-send-string process (herdr-api--encode id method params))
          (herdr-api--decode (herdr-api--read-reply process method)
                             id method))
      (delete-process process))))

(defun herdr-api--next-id ()
  "Return an identifier no other pending request is using."
  (setq herdr-api--request-counter (1+ herdr-api--request-counter))
  (format "emacs-%d" herdr-api--request-counter))

(defun herdr-api--encode (id method params)
  "Return the request line for METHOD with PARAMS, tagged ID."
  (concat (json-serialize (list :id id
                                :method method
                                ;; An explicit empty object, because a nil
                                ;; plist value is ambiguous and the server
                                ;; rejects a request that omits `params'.
                                :params (or params
                                            (make-hash-table :size 1))))
          "\n"))

(defun herdr-api--reply-filter (process chunk)
  "Accumulate CHUNK on PROCESS until a whole reply line has arrived."
  (process-put process 'herdr-api-pending
               (concat (process-get process 'herdr-api-pending) chunk)))

(defun herdr-api--pending-line (process)
  "Return the first complete line PROCESS has accumulated, or nil."
  (let* ((pending (process-get process 'herdr-api-pending))
         (end (and pending (string-search "\n" pending))))
    (and end (substring pending 0 end))))

(defun herdr-api--read-reply (process method)
  "Return the line PROCESS sends in answer to METHOD.
Signal `herdr-api-unavailable' when the server closes without
answering or stays silent for `herdr-api-timeout' seconds."
  (let ((deadline (+ (float-time) herdr-api-timeout)))
    (while (and (not (herdr-api--pending-line process))
                (process-live-p process)
                (< (float-time) deadline))
      (accept-process-output process 0.05))
    (cond
      ((herdr-api--pending-line process))
      ((process-live-p process)
       (signal 'herdr-api-unavailable
               (list (format "herdr did not answer %s within %s seconds"
                             method herdr-api-timeout))))
      (t
       (signal 'herdr-api-unavailable
               (list (format "herdr closed the connection answering %s"
                             method)))))))

(defun herdr-api--decode (line id method)
  "Return the result carried by reply LINE to request ID calling METHOD.
Signal `herdr-api-rejected' when herdr reports an error, and
`herdr-api-error' when the reply is not one this client can read."
  (let ((reply (herdr-api--parse line)))
    (unless (hash-table-p reply)
      (signal 'herdr-api-error
              (list (format "herdr answered %s with invalid JSON" method))))
    ;; Before the identifier, because herdr answers a request it could not
    ;; parse with an empty one.
    (when-let* ((body (gethash "error" reply)))
      (signal 'herdr-api-rejected
              (list (format "%s: %s (%s)" method
                            (gethash "message" body)
                            (gethash "code" body)))))
    (unless (equal (gethash "id" reply) id)
      (signal 'herdr-api-error
              (list (format "herdr answered %s under another id" method))))
    ;; `missing' tells an absent result from one that is JSON null, which
    ;; decodes to nil exactly as an absent one would.
    (let ((result (gethash "result" reply 'missing)))
      (when (eq result 'missing)
        (signal 'herdr-api-error
                (list (format "herdr answered %s without a result" method))))
      result)))

(defun herdr-api--parse (line)
  "Return LINE decoded from JSON, or nil when it is not JSON.
JSON false and null both decode to nil, so that a missing field and a
false one can be tested alike."
  (condition-case nil
      (json-parse-string line :false-object nil :null-object nil)
    (error nil)))

;;; Events

(defun herdr-api-subscribe (events callback &optional on-close)
  "Subscribe to EVENTS and call CALLBACK with each one that arrives.
EVENTS is a list of subscription names such as \"pane.updated\".
CALLBACK receives one decoded event hash-table per event, whose `event'
field names the event with underscores rather than dots.

ON-CLOSE, when given, is called with a string saying why the
subscription ended, whether herdr refused it or the connection
dropped.  Without it a caller cannot tell a quiet server from a dead
one, and will show stale state indefinitely.  It is not called when
`herdr-api-unsubscribe' ends the subscription, which is not news.

Return the process holding the subscription.  Do not replace its
filter or its sentinel; they own the accumulator this reads.

Unlike a request, this connection stays open: herdr acknowledges the
subscription and then pushes events on it until it closes.  CALLBACK
runs inside a process filter, so it must not block; see
`herdr-api-request' for what happens when it does."
  (let ((process (herdr-api--connect "herdr-api-events")))
    (process-put process 'herdr-api-callback callback)
    (process-put process 'herdr-api-on-close on-close)
    (process-put process 'herdr-api-pending "")
    (process-put process 'herdr-api-queue nil)
    (set-process-filter process #'herdr-api--event-filter)
    (set-process-sentinel process #'herdr-api--event-sentinel)
    (process-send-string
     process
     (herdr-api--encode
      (herdr-api--next-id) "events.subscribe"
      (list :subscriptions
            (vconcat (mapcar (lambda (event) (list :type event)) events)))))
    process))

(defun herdr-api-unsubscribe (process)
  "End the subscription held by PROCESS.
This is a deliberate stop, so the handler given to
`herdr-api-subscribe' is not told about it.  A nil or already dead
PROCESS is accepted, because teardown paths run more than once."
  (when (processp process)
    (process-put process 'herdr-api-on-close nil)
    (when (process-live-p process)
      (set-process-filter process #'ignore)
      (set-process-sentinel process #'ignore)
      (delete-process process))))

(defun herdr-api--event-sentinel (process event)
  "Tell PROCESS's handler that EVENT ended its subscription."
  (unless (process-live-p process)
    (herdr-api--closed process (string-trim event))))

(defun herdr-api--closed (process reason)
  "End PROCESS's subscription, telling its handler REASON exactly once."
  (let ((on-close (process-get process 'herdr-api-on-close)))
    (herdr-api-unsubscribe process)
    (when on-close
      (funcall on-close reason))))

(defun herdr-api--event-filter (process chunk)
  "Queue every complete line in CHUNK from PROCESS, then deliver them."
  (let* ((pending (concat (process-get process 'herdr-api-pending) chunk))
         (parts (split-string pending "\n")))
    (process-put process 'herdr-api-pending (car (last parts)))
    (process-put process 'herdr-api-queue
                 (append (process-get process 'herdr-api-queue)
                         (butlast parts))))
  (herdr-api--drain process))

(defun herdr-api--drain (process)
  "Deliver the lines queued on PROCESS to its callback, oldest first.
A callback may block, and blocking runs other process filters, so this
filter can be entered again while a callback of an earlier batch is
still running.  Draining one shared queue under a guard is what keeps
events in arrival order: delivering straight from the filter would let
the newer batch overtake the older one."
  (unless (process-get process 'herdr-api-draining)
    (process-put process 'herdr-api-draining t)
    (unwind-protect
        (while (process-get process 'herdr-api-queue)
          (let ((line (car (process-get process 'herdr-api-queue))))
            (process-put process 'herdr-api-queue
                         (cdr (process-get process 'herdr-api-queue)))
            (herdr-api--deliver process line)))
      (process-put process 'herdr-api-draining nil))))

(defun herdr-api--deliver (process line)
  "Hand the event on LINE to the callback of PROCESS.
An error reply travels the same connection as the events and means the
subscription was refused; treating it as \"not an event\" would leave
the caller waiting on a stream that will never carry one.  The
acknowledgement is a result rather than an event and is not delivered."
  (unless (string-empty-p line)
    (let ((message (herdr-api--parse line)))
      (when (hash-table-p message)
        (cond
          ((gethash "error" message)
           (let ((body (gethash "error" message)))
             (herdr-api--closed process
                                (format "subscription refused: %s (%s)"
                                        (gethash "message" body)
                                        (gethash "code" body)))))
          ((gethash "event" message)
           ;; A signal here would abandon the rest of the queue, and a
           ;; process filter is nowhere for a backtrace to go.
           (with-demoted-errors "herdr-api event callback: %S"
             (funcall (process-get process 'herdr-api-callback)
                      message))))))))

;;; _
(provide 'herdr-api)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-api.el ends here
