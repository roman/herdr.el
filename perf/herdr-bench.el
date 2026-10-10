;;; herdr-bench.el --- Measure one herdr.el session in a live Emacs  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Roman Gonzalez

;; Author: Roman Gonzalez <antrophic@roman-gonzalez.info>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `run.sh' loads this file into a graphical `emacs -Q' after the
;; herdr.el revision under test.  It opens the herdr UI against the
;; fixture server, lets a warm-up pass, measures a steady window,
;; appends one JSON object to HERDR_BENCH_OUT and exits.

;; Every probe observes herdr.el from outside: advice on the process
;; primitives, and a one-shot timer that measures how late it fires.
;; A revision is therefore measured without edits to it.  The harness
;; does depend on `herdr-ui' and `herdr-term-open' taking a pane id,
;; and reports the API figures as null for a revision older than
;; `herdr-api-traffic'.

;; The probes are configured through the environment:
;;
;;   HERDR_BENCH_OUT      JSON lines file to append the result to
;;   HERDR_BENCH_LABEL    name of the variant under test
;;   HERDR_BENCH_PANES    space separated pane ids; the first gets
;;                        the UI with control, the rest observe
;;   HERDR_BENCH_WARMUP   seconds before the window opens (10)
;;   HERDR_BENCH_SECONDS  length of the measured window (60)
;;   HERDR_BENCH_PROFILE  when set, a file to save the window's CPU
;;                        profile report to, as text
;;   HERDR_BENCH_MARKER   when set, a file created when the window
;;                        opens, so an outside probe can start with it

;;; Code:

(require 'json)
(require 'profiler)
(require 'herdr-ui)
(require 'herdr-term)
(require 'herdr-api)

;;; Variables

(defconst herdr-bench-tick 0.02
  "Seconds between two firings of the lateness probe.")

(defconst herdr-bench-stall-threshold 0.05
  "Lateness in seconds above which a probe firing counts as a stall.
Fifty milliseconds is roughly where a typed character starts to feel
late.")

(defvar herdr-bench--measuring nil
  "Non-nil while the measured window is open.")

(defvar herdr-bench--launches (make-hash-table :test #'equal)
  "Process launches seen in the window, keyed by program name.
Each value has the form (COUNT . SECONDS), where SECONDS is how long
the launching call kept the main thread busy.")

(defvar herdr-bench--connects '(0 . 0.0)
  "Socket connections opened in the window, as (COUNT . SECONDS).
Kept apart from `herdr-bench--launches' because a connect is not an
exec, and the exec shims of `run.sh' do not slow it down.")

(defvar herdr-bench--wait-depth 0
  "How many `accept-process-output' calls are running right now.
Emacs runs timers inside such a wait, but keeps keyboard input queued
until it returns, so a probe firing there is not on time for the
user.")

(defvar herdr-bench--lateness nil
  "Lateness of each probe firing in the window, in seconds.")

(defvar herdr-bench--last-tick nil
  "When the lateness probe last fired, as a float time.")

(defvar herdr-bench--window-start nil
  "Counters sampled when the window opened, as a plist.")

(defvar herdr-bench--result nil
  "Alist of facts gathered outside the window, such as startup time.")

;;; Probes

(defun herdr-bench--env (name default)
  "Return environment variable NAME, or DEFAULT when it is unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun herdr-bench--add (entry seconds)
  "Return ENTRY, a (COUNT . SECONDS) pair, with one call of SECONDS added."
  (cons (1+ (car entry)) (+ (cdr entry) seconds)))

(defun herdr-bench--launch (program function arguments)
  "Apply FUNCTION to ARGUMENTS and record it as a launch of PROGRAM.
Launching a process blocks the main thread until the child has
executed, so the time spent here includes whatever an endpoint
security agent adds to `execve'."
  (let ((start (float-time)))
    (unwind-protect
        (apply function arguments)
      (when herdr-bench--measuring
        (puthash program
                 (herdr-bench--add
                  (gethash program herdr-bench--launches '(0 . 0.0))
                  (- (float-time) start))
                 herdr-bench--launches)))))

(defun herdr-bench--around-make-process (function &rest arguments)
  "Record a `make-process' call made with ARGUMENTS, then run FUNCTION."
  (let ((command (car (plist-get arguments :command))))
    (herdr-bench--launch (if command (file-name-nondirectory command)
                           "<no command>")
                         function arguments)))

(defun herdr-bench--around-call-process (function program &rest arguments)
  "Record a synchronous call of PROGRAM with ARGUMENTS through FUNCTION.
`process-file' reaches this for local directories, so it is counted
once, here."
  (herdr-bench--launch (file-name-nondirectory program)
                       function (cons program arguments)))

(defun herdr-bench--around-network-process (function &rest arguments)
  "Record a `make-network-process' call made with ARGUMENTS via FUNCTION."
  (let ((start (float-time)))
    (unwind-protect
        (apply function arguments)
      (when herdr-bench--measuring
        (setq herdr-bench--connects
              (herdr-bench--add herdr-bench--connects
                                (- (float-time) start)))))))

(defun herdr-bench--around-accept-process-output (function &rest arguments)
  "Run FUNCTION with ARGUMENTS while counting it in the wait depth."
  (let ((herdr-bench--wait-depth (1+ herdr-bench--wait-depth)))
    (apply function arguments)))

(defun herdr-bench--tick ()
  "Record how late this firing is, then schedule the next one.
A one-shot timer is rescheduled instead of a repeating one, because
Emacs replays a late repeating timer up to `timer-max-repeats' times
and those replays would hide the stall behind short gaps.  A firing
inside `accept-process-output' records nothing and keeps the previous
firing time, so the next firing outside the wait measures the whole
time input was held."
  (when (zerop herdr-bench--wait-depth)
    (let ((now (float-time)))
      (when (and herdr-bench--measuring herdr-bench--last-tick)
        (push (max 0.0 (- now herdr-bench--last-tick herdr-bench-tick))
              herdr-bench--lateness))
      (setq herdr-bench--last-tick now)))
  (run-at-time herdr-bench-tick nil #'herdr-bench--tick))

(defun herdr-bench--cpu-seconds ()
  "Return the user plus system CPU seconds this Emacs has used.
`get-internal-run-time' reads `getrusage'.  `process-attributes' is
avoided because on Apple silicon it reports Mach ticks as if they
were nanoseconds, which understates CPU time about forty times."
  (float-time (get-internal-run-time)))

(defun herdr-bench--sample ()
  "Return the cumulative counters the window subtracts, as a plist."
  (list :time (float-time)
        :cpu (herdr-bench--cpu-seconds)
        :gcs gcs-done
        :gc-seconds gc-elapsed
        :traffic (and (fboundp 'herdr-api-traffic)
                      (herdr-api-traffic))))

;;; Results

(defun herdr-bench--percentile (sorted fraction)
  "Return the FRACTION percentile of the ascending list SORTED."
  (if sorted
      (nth (min (1- (length sorted))
                (floor (* fraction (length sorted))))
           sorted)
    0.0))

(defun herdr-bench--requests (before after)
  "Return per-method request counts between traffic BEFORE and AFTER."
  (let ((was (plist-get before :requests)))
    (mapcar (lambda (request)
              (cons (car request)
                    (- (plist-get (cdr request) :count)
                       (or (plist-get (cdr (assoc (car request) was))
                                      :count)
                           0))))
            (plist-get after :requests))))

(defun herdr-bench--traffic-summary (before after)
  "Return API figures between traffic samples BEFORE and AFTER, as an alist.
Each figure is nil when this herdr.el predates `herdr-api-traffic'."
  `((api_requests . ,(and after (herdr-bench--requests before after)))
    (api_blocked_seconds
     . ,(and after (- (plist-get after :blocked-seconds)
                      (plist-get before :blocked-seconds))))
    (api_events . ,(and after (- (plist-get after :events)
                                 (plist-get before :events))))))

(defun herdr-bench--summary ()
  "Return the measured window as an alist ready for `json-encode'."
  (let* ((end (herdr-bench--sample))
         (start herdr-bench--window-start)
         (seconds (- (plist-get end :time) (plist-get start :time)))
         (lateness (sort (copy-sequence herdr-bench--lateness) #'<))
         (launches nil)
         (launch-total '(0 . 0.0)))
    (maphash (lambda (program entry)
               (push (list program
                           (cons 'count (car entry))
                           (cons 'seconds (cdr entry)))
                     launches)
               (setq launch-total
                     (cons (+ (car launch-total) (car entry))
                           (+ (cdr launch-total) (cdr entry)))))
             herdr-bench--launches)
    (append
     herdr-bench--result
     `((window_seconds . ,seconds)
       (cpu_seconds . ,(- (plist-get end :cpu) (plist-get start :cpu)))
       (gcs . ,(- (plist-get end :gcs) (plist-get start :gcs)))
       (gc_seconds . ,(- (plist-get end :gc-seconds)
                         (plist-get start :gc-seconds)))
       (launches . ,launches)
       (launch_count . ,(car launch-total))
       (launch_blocking_seconds . ,(cdr launch-total))
       (connect_count . ,(car herdr-bench--connects))
       (connect_seconds . ,(cdr herdr-bench--connects))
       (lateness_p50 . ,(herdr-bench--percentile lateness 0.50))
       (lateness_p95 . ,(herdr-bench--percentile lateness 0.95))
       (lateness_p99 . ,(herdr-bench--percentile lateness 0.99))
       (lateness_max . ,(if lateness (car (last lateness)) 0.0))
       (stall_seconds
        . ,(apply #'+ 0.0 (seq-filter
                           (lambda (late)
                             (> late herdr-bench-stall-threshold))
                           lateness))))
     (herdr-bench--traffic-summary (plist-get start :traffic)
                                   (plist-get end :traffic)))))

(defun herdr-bench--write (alist)
  "Append ALIST as one JSON line to HERDR_BENCH_OUT."
  (let ((json-encoding-pretty-print nil))
    (write-region (concat (json-encode alist) "\n") nil
                  (herdr-bench--env "HERDR_BENCH_OUT"
                                    "herdr-bench.jsonl")
                  'append 'silent)))

;;; Scenario

(defun herdr-bench--open-window ()
  "Reset the probes and open the measured window."
  (clrhash herdr-bench--launches)
  (setq herdr-bench--connects '(0 . 0.0)
        herdr-bench--lateness nil
        herdr-bench--window-start (herdr-bench--sample)
        herdr-bench--measuring t)
  (when (herdr-bench--env "HERDR_BENCH_PROFILE" nil)
    (profiler-start 'cpu))
  (when-let* ((marker (herdr-bench--env "HERDR_BENCH_MARKER" nil)))
    (write-region "" nil marker nil 'silent)))

(defun herdr-bench--save-profile (file)
  "Stop the CPU profiler and save its fully expanded report to FILE.
Text can be read over SSH and compared between runs with `diff'.
The profiler is stopped first, because `profiler-stop' is what copies
the samples into `profiler-cpu-log', which `profiler-cpu-profile' reads."
  (profiler-stop)
  (let ((buffer (profiler-report-setup-buffer (profiler-cpu-profile))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (not (eobp))
        (profiler-report-expand-entry t)
        (forward-line 1))
      (write-region nil nil file nil 'silent))))

(defun herdr-bench--close-window ()
  "Close the measured window, write the result and exit Emacs.
A failure here still writes a result, so `run.sh' does not wait for
the watchdog."
  (setq herdr-bench--measuring nil)
  (condition-case condition
      (progn
        (when-let* ((file (herdr-bench--env "HERDR_BENCH_PROFILE" nil)))
          (herdr-bench--save-profile file))
        (herdr-bench--write (herdr-bench--summary))
        (kill-emacs 0))
    (error (herdr-bench--fail condition))))

(defun herdr-bench--fail (condition)
  "Write CONDITION as the run's result and exit Emacs with status 1."
  (herdr-bench--write
   (append herdr-bench--result
           `((error . ,(error-message-string condition)))))
  (kill-emacs 1))

(defun herdr-bench-run ()
  "Open the herdr UI on the fixture panes and measure a steady window.
The UI open is timed separately as `startup_seconds', because it
launches every stream process at once and would otherwise swamp the
steady-state figures."
  (let ((panes (split-string (herdr-bench--env "HERDR_BENCH_PANES" "")))
        (warmup (string-to-number (herdr-bench--env "HERDR_BENCH_WARMUP"
                                                    "10")))
        (seconds (string-to-number (herdr-bench--env "HERDR_BENCH_SECONDS"
                                                     "60"))))
    (setq herdr-bench--result
          `((label . ,(herdr-bench--env "HERDR_BENCH_LABEL" "unnamed"))
            (emacs . ,emacs-version)
            (window_system . ,(format "%s" window-system))
            (panes . ,(length panes))
            (profiled . ,(if (herdr-bench--env "HERDR_BENCH_PROFILE" nil)
                             t
                           :json-false))))
    (run-at-time (+ warmup seconds 120) nil #'kill-emacs 2)
    (condition-case condition
        (let ((start (float-time)))
          (herdr-ui (car panes))
          (dolist (pane (cdr panes))
            (save-window-excursion (herdr-term-open pane)))
          (push (cons 'startup_seconds (- (float-time) start))
                herdr-bench--result))
      (error (herdr-bench--fail condition)))
    (herdr-bench--tick)
    (run-at-time warmup nil #'herdr-bench--open-window)
    (run-at-time (+ warmup seconds) nil #'herdr-bench--close-window)))

(advice-add 'make-process :around #'herdr-bench--around-make-process)
(advice-add 'call-process :around #'herdr-bench--around-call-process)
(advice-add 'make-network-process :around
            #'herdr-bench--around-network-process)
(advice-add 'accept-process-output :around
            #'herdr-bench--around-accept-process-output)

;;; _
(provide 'herdr-bench)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; herdr-bench.el ends here
