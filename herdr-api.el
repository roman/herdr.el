;;; herdr-api.el --- Talk to the herdr server  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <open-source@roman-gonzalez.info>
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
;; documents for third-party tools.  This file carries requests and
;; events, and counts them: it knows no method names, so what herdr adds
;; next needs no change here.  The one buffer it builds is the traffic
;; report, which names no method either.  Live terminal output does not
;; travel this socket at all; see `herdr-term' for that.

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

;; Because a connection is spent per request and callers decide how many
;; to make, every request and every event is counted as it passes.
;; `herdr-api-report-traffic' shows the counts and `herdr-api-traffic'
;; returns them as data; see the Traffic section below.

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

;;; Traffic

;; Every request and every event is counted, so that a session which
;; feels slow can be measured rather than guessed at.  Nothing here
;; decides how many requests there are: a caller that refreshes on each
;; event makes one request per event, and a pane running an agent
;; produces several events a second.  The two counts read together say
;; whether the server is talkative or the caller wasteful.

;; Counting is unconditional.  It costs one hash-table write per
;; request, and a counter that must be switched on first is never on
;; when the slowness happens.

;; The counts only ever rise, which is the shape a metrics exporter
;; needs; see `herdr-api-traffic'.  `herdr-api-reset-traffic' moves the
;; window the report covers instead of clearing them.

;; Waiting is counted per method and again in total.  A method keeps the
;; whole span of its own calls.  The total keeps only the spans that no
;; other request was already inside, because waiting for a reply runs
;; timers and process filters: a refresh timer firing inside an outer
;; wait would otherwise be counted twice, and the total would exceed the
;; window it is printed against.

(defconst herdr-api--traffic-columns "%-24s %8s %9s %10s %10s\n"
  "Format of one row of the traffic report, taking five strings.")

(defvar herdr-api--traffic (make-hash-table :test #'equal)
  "Requests made, keyed by method name.
Each value has the form (COUNT SECONDS), SECONDS being how long those
calls waited for their replies.  Neither figure is ever reduced.")

(defvar herdr-api--traffic-slowest (make-hash-table :test #'equal)
  "The longest single wait of each method, keyed by method name.
Cleared by `herdr-api-reset-traffic', because the longest wait of a
window cannot be worked out from two cumulative counts.")

(defvar herdr-api--traffic-blocked 0
  "Seconds waited with no other request already waiting.
Never reduced.  This is what the report totals, rather than the sum of
the per-method times; see the commentary above.")

(defvar herdr-api--traffic-events 0
  "Events delivered to subscribers.  Never reduced.")

(defvar herdr-api--traffic-depth 0
  "How many requests are waiting for a reply at this moment.")

(defvar herdr-api--traffic-since (float-time)
  "When the window `herdr-api-report-traffic' covers began.")

(defvar herdr-api--traffic-baseline nil
  "The counts as they stood when that window began, or nil.
Takes the form `herdr-api-traffic' returns.  The report subtracts it,
which is what lets the counts themselves go on rising.")

(defun herdr-api--note-request (method start)
  "Count one call of METHOD that began waiting at START."
  (let* ((seconds (- (float-time) start))
         (entry (gethash method herdr-api--traffic))
         (slowest (gethash method herdr-api--traffic-slowest)))
    (puthash method
             (list (1+ (or (nth 0 entry) 0))
                   (+ (or (nth 1 entry) 0) seconds))
             herdr-api--traffic)
    (puthash method (max (or slowest 0) seconds)
             herdr-api--traffic-slowest)
    (when (= herdr-api--traffic-depth 1)
      (setq herdr-api--traffic-blocked
            (+ herdr-api--traffic-blocked seconds)))))

(defun herdr-api--note-event ()
  "Count one event delivered to a subscriber."
  (setq herdr-api--traffic-events (1+ herdr-api--traffic-events)))

(defun herdr-api-traffic ()
  "Return what has crossed this socket so far, as a plist.

  (:requests ((METHOD . (:count COUNT :seconds SECONDS
                         :slowest SECONDS)) ...)
   :blocked-seconds SECONDS
   :events COUNT)

Every count and every total is cumulative: it rises for as long as
Emacs runs and is never reduced.  Sample it twice and subtract to get
a rate.  That is what a Prometheus counter is, so exporting these
needs no more than a scrape endpoint, and nothing here has to know
what Prometheus is.  Times are in seconds, the unit such an exporter
expects.

`:slowest' is the one exception and behaves as a gauge: it holds the
longest single wait since `herdr-api-reset-traffic' last ran, because
a maximum cannot be recovered by subtracting two totals."
  (let ((requests nil))
    (maphash
     (lambda (method entry)
       (push (cons method
                   (list :count (nth 0 entry)
                         :seconds (nth 1 entry)
                         :slowest (or (gethash method
                                               herdr-api--traffic-slowest)
                                      0)))
             requests))
     herdr-api--traffic)
    (list :requests requests
          :blocked-seconds herdr-api--traffic-blocked
          :events herdr-api--traffic-events)))

(defun herdr-api--traffic-delta (key now was)
  "Return the KEY of plist NOW less the KEY of plist WAS."
  (- (or (plist-get now key) 0) (or (plist-get was key) 0)))

(defun herdr-api--traffic-rows ()
  "Return (METHOD COUNT SECONDS SLOWEST) per method, busiest first.
These cover the current report window rather than the whole run, and a
method untouched since the window opened is left out."
  (let ((baseline (plist-get herdr-api--traffic-baseline :requests))
        (rows nil))
    (dolist (request (plist-get (herdr-api-traffic) :requests))
      (let* ((now (cdr request))
             (was (cdr (assoc (car request) baseline)))
             (count (herdr-api--traffic-delta :count now was)))
        (unless (zerop count)
          (push (list (car request) count
                      (herdr-api--traffic-delta :seconds now was)
                      (plist-get now :slowest))
                rows))))
    (sort rows (lambda (a b) (> (nth 1 a) (nth 1 b))))))

(defun herdr-api--traffic-row (label count seconds slowest elapsed)
  "Return the report row named LABEL, covering COUNT of something.
SECONDS is how long they waited in total, SLOWEST the longest single
wait among them, and ELAPSED the width of the window they were counted
over.  SECONDS and SLOWEST may be nil, for a row counting something
that never waits."
  (format herdr-api--traffic-columns label
          (number-to-string count)
          (format "%.2f" (/ count elapsed))
          (if seconds (format "%.2fs" seconds) "")
          (if slowest (format "%.2fs" slowest) "")))

;;;###autoload
(defun herdr-api-report-traffic ()
  "Show what this Emacs has asked of the herdr server, and how often.
Each rate is an average over the whole window, so one burst and a
steady trickle of the same size read alike.  Call
`herdr-api-reset-traffic', wait a known stretch, and report again to
measure that stretch on its own.

The blocked column is how long Emacs spent waiting for replies, and
the slowest column the longest single wait.  A request that timed out
shows in the second and is lost in the first.  The total counts a
stretch of waiting once however many requests were nested in it, so it
can be less than the rows above it add up to.

The events row counts what arrived on the subscriptions.  Divided into
the request count, it says how many requests each event costs.

Call `herdr-api-traffic' for the same figures as data."
  (interactive)
  (let ((elapsed (max (- (float-time) herdr-api--traffic-since) 0.001))
        (baseline herdr-api--traffic-baseline)
        (rows (herdr-api--traffic-rows)))
    (with-current-buffer (get-buffer-create "*herdr-api-traffic*")
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "herdr API traffic over %.1f seconds\n\n" elapsed))
        (insert (format herdr-api--traffic-columns
                        "Method" "Count" "Per sec" "Blocked" "Slowest"))
        (dolist (row rows)
          (insert (herdr-api--traffic-row (nth 0 row) (nth 1 row)
                                          (nth 2 row) (nth 3 row) elapsed)))
        (insert (herdr-api--traffic-row
                 "total"
                 (apply #'+ (mapcar (lambda (row) (nth 1 row)) rows))
                 (- herdr-api--traffic-blocked
                    (or (plist-get baseline :blocked-seconds) 0))
                 (apply #'max 0 (mapcar (lambda (row) (nth 3 row)) rows))
                 elapsed))
        (insert "\n")
        (insert (herdr-api--traffic-row "events received"
                                        (- herdr-api--traffic-events
                                           (or (plist-get baseline :events)
                                               0))
                                        nil nil elapsed)))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;;###autoload
(defun herdr-api-reset-traffic ()
  "Begin a fresh window for `herdr-api-report-traffic'.
The counts are not cleared, because a caller sampling them for a
metrics system needs them to keep rising; see `herdr-api-traffic'.
What is recorded is where the window starts, and the report subtracts
that.  The slowest wait of each method is the exception and is
forgotten, being the one figure no subtraction recovers."
  (interactive)
  (setq herdr-api--traffic-baseline (herdr-api-traffic)
        herdr-api--traffic-since (float-time))
  (clrhash herdr-api--traffic-slowest)
  (message "herdr-api: reporting from here on"))

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
expires, with no way to interrupt it.

The call is timed for `herdr-api-report-traffic', a failed one
included: a request that could not reach the server is the slowest of
all, and leaving it out of the count would hide it."
  (let ((start (float-time))
        (herdr-api--traffic-depth (1+ herdr-api--traffic-depth)))
    (unwind-protect
        (herdr-api--exchange method params)
      (herdr-api--note-request method start))))

(defun herdr-api--exchange (method params)
  "Spend one connection calling METHOD with PARAMS and return its result.
See `herdr-api-request', which is this plus the timing and is what
callers use."
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
           (herdr-api--note-event)
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
