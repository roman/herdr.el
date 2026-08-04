---
topic: herdr.el's refresh cadence traced and instrumented, Linux measured at 1.1 requests/second and cleared as the cause of the macOS slowness, reviewed and landed
date: 2026-08-04
status: Landed on master at 1b91291, not pushed, 202 tests green, one code-critic pass and one human review closed with three comments addressed; the macOS measurement this was built for has not been taken
Recurring-friction: passing-test-without-teeth
---

# Handoff: the API traffic counter landed, and Linux is not the bottleneck

Roman asked whether herdr.el polls the herdr server or listens for
notifications, because herdr on macOS had become slow enough to be unusable and
Emacs was a suspect. The answer is both, and the mix is what made a guess
unsafe.

`herdr-session-start` opens one `events.subscribe` connection per Emacs
(`herdr-session.el:146`) — real push, not polling, and one for the whole session
rather than one per panel. But the tree is never patched from an event. Each
event schedules a full `session.snapshot` request, debounced by
`herdr-session-refresh-delay` at 0.15s, and a repeating `herdr-session-poll-interval`
timer takes another snapshot every 5 seconds whether or not anything happened.
Every one of those snapshots opens a fresh unix socket, blocks in
`accept-process-output` until the reply lands, and drops the connection
(`herdr-api.el`). The file's own commentary says a pane running an agent reports
events several times a second, so I could bound the rate at roughly 6.6
snapshots per second and no tighter than that. Bounding it is not measuring it,
which is what the rest of the session was about.

One thing that does *not* travel this socket: live terminal output. Each open
pane buffer spawns a `herdr terminal session observe|control` subprocess
(`herdr-term.el:451`). That is separate server load and nothing here counts it.

## What I built

A `;;; Traffic` section in `herdr-api.el`. Every request is counted under its
method with the time it waited, every event delivered to a subscriber is
counted, and `herdr-api-report-traffic` renders the lot.

Counting is unconditional. A counter that has to be switched on first is never
on when the slowness happens, and the cost is one hash-table write per request.

Waiting is counted per method and again in total, and the two are deliberately
different numbers — see the bug below.

## What the numbers said

A 30-second window against the live server on Roman's Linux machine, with
agents working:

| | Count | Per sec | Blocked | Slowest |
| --- | --- | --- | --- | --- |
| `session.snapshot` | 33 | 1.10 | 0.09s | 0.01s |
| events received | 117 | 3.90 | | |

So my 6.6/second bound was the worst case and the real figure was a sixth of
it: the 0.15s debounce coalesces about 3.5 events into each snapshot. Emacs
blocked 0.09 seconds out of 30, which is 0.3% of wall clock. On this machine
the client is not overwhelming anything.

A second run with the session idle showed 3 requests in 15 seconds and zero
events — the 5-second poll alone, which is the floor when nothing is happening.

## The bug code-critic found

The first draft timed each request and added every span to one total. That is
wrong, and wrong in exactly the case the instrument exists to measure.
`herdr-api--read-reply` sits in `accept-process-output`, which runs timers, so
`herdr-session`'s 0.15s refresh timer can fire *inside* an outer request's wait
and complete a second request there. Both spans were added, so the total could
exceed the window it was printed against — and the slower the server, the wider
the overlap and the more inflated the figure.

`herdr-api-request` now dynamically binds `herdr-api--traffic-depth`, and only a
request that finds itself at depth 1 adds to the total. Per-method times stay
inclusive, because a method's own latency is what that column is for.

I verified the regression test against the unfixed code rather than trusting it:
two 0.2s spans, one nested, produce 0.400s unfixed and 0.200s fixed.

## What the review changed

Roman left three comments. Two were about prose — the Traffic commentary was
cheesier than the house style and one clause ("because two questions are being
asked") earned nothing. I rewrote the section and the docstrings, since the
objection was to the register rather than to those two lines.

The third was the substantial one: how is an API user supposed to use these
functions, and is this friendly to Prometheus?

They could not use them at all. Every counter was `--` private and the only way
in was reading a report buffer. And the design was actively hostile to a
scraper: `herdr-api-reset-traffic` zeroed the counters, which a Prometheus
scraper reads as a restarted process, discarding every rate that spans the
reset.

`herdr-api-traffic` now returns the figures as data, and everything in it is
cumulative and never reduced — sample twice, subtract, get a rate, which is what
a Prometheus counter is. Reset records where the report's window starts and the
report subtracts that baseline, so the counters go on climbing underneath it.
Verified live: across a reset the count went 30 → 33 while the report window
correctly showed 3.

The longest single wait is the one exception and is documented as a gauge. No
subtraction recovers a maximum, so it is kept in its own table and forgotten on
reset. It is also the column where a request that hit the 5-second
`herdr-api-timeout` shows up instead of being buried in a mean.

**I declined to bundle a Prometheus library.** An exporter needs an HTTP
endpoint to scrape, which means a listening socket inside the user's Emacs —
too much to carry for a diagnostic. The cumulative shape means anyone who wants
one can write it in about ten lines against `herdr-api-traffic`, and
`herdr-api.el` never has to know Prometheus exists. Roman accepted this; if it
is ever wanted in-tree it should go behind an optional require.

## Facts worth keeping

- **`float-time` rounds, so exact boundary assertions on elapsed time flake.**
  `(- (float-time) 0.3)` fed back through a delta came out as
  `0.2999999523162842`, and `(>= it 0.3)` failed. Both timing tests now assert
  well clear of the span rather than exactly on it.
- **A `defvar` let-bound around the work is how to get nesting depth right.**
  The cleanup form of an `unwind-protect` runs before the enclosing `let`
  unwinds, so the outermost request still sees its own binding of depth 1 when
  it records. No manual increment/decrement pair, and no leak on a signal.
- **The review showed four commits, not one.** Review marker 5 sat at `184f5a4`,
  so three commits from earlier sessions had never been read. Worth checking
  `herdr-review marks` against `git log` before telling someone what a review
  contains.
- **Batch Emacs is enough to exercise this.** `herdr-session` requires only
  `herdr-api` and `seq`, so `emacs -Q --batch -L . --eval '(herdr-session-start)'`
  measures the tracking layer against the live server without ghostel, a frame,
  or any panel. That is how both tables above were produced.

## Current state

One commit, `1b91291`, touching `herdr-api.el` and `test/herdr-api-tests.el`
only. It replaces the two commits the session carried, collapsed once the review
closed, and review marker 6 was moved onto it so the next review starts from
here.

**Not pushed.** `origin/master` is still at `4a51267`.

`just check` passes: every file byte-compiles under `byte-compile-error-on-warn`,
all 202 ERT tests pass, and `check-declare` and `checkdoc` are silent.

## Next steps

- Run `M-x herdr-api-report-traffic` on the Mac. This is the entire reason the
  instrument exists and it has not been done.
- Read the result this way: `Per sec` climbing means the server emits more
  events there; `Blocked` and `Slowest` climbing at a similar request rate means
  the socket or the server is slow, not the volume.
- If the rate is the problem, `herdr-session-poll-interval` set to nil and
  `herdr-session-refresh-delay` raised to 1.0 are the two knobs, both
  `defcustom`.

## Gaps

- **The report does not count the terminal streams.** One
  `herdr terminal session` subprocess per open pane, none of it on the API
  socket. If the Mac's problem is there, this instrument will show a quiet
  client and be right about the wrong thing.
- **Nor panel redraw.** That cost is Emacs-side, not server load, and a snapshot
  that changes nothing visible is dropped before any panel redraws — but a
  panel-heavy frame was never measured.
- **The Linux baseline came from batch Emacs with no panels drawing and no
  terminal buffers open.** It is a clean measurement of the tracking layer and
  not of a working session.
- **Per-method times remain inclusive of nested waits.** Documented, and correct
  for a latency column, but a reader who sums that column and compares it to the
  total will find they disagree.

## Skills and meta

- **Skills used.** `elisp-development` for the file conventions and the
  compile/checkdoc gate; `code-critic` for the pre-review pass; `herdr:review`
  to open the review, read the comments back and collapse the rounds;
  `writing:handoff` here.
- **Steering.** Roman's Prometheus question changed the design rather than
  adding to it. I had written private counters with a reset that cleared them,
  which is fine for a human reading a buffer once and unusable for anything
  else. The question "is this friendly to X" was worth more than a request to
  add X would have been — and the right answer still included declining the
  library.
- **Steering.** `code-critic` caught the nested double-count, which I had not
  considered at all: I knew `accept-process-output` runs timers, and had written
  that fact into a docstring in this very change, without connecting it to my
  own accounting. A fact stated in prose is not a fact applied.
- **Steering.** Roman objected to the prose register twice in one review. The
  house style in this repo is discursive, and I overshot it into theatrical. The
  correction generalised — I rewrote the docstrings too, not just the two lines
  flagged.
- **Meta.** `passing-test-without-teeth` again, and caught only because I ran the
  new regression test against the unfixed code. My first bound was `< 0.4`
  against an unfixed value of `0.400` — it would have passed or failed on
  floating-point noise. Verifying a regression test against the bug is the step
  that turns it into a test; without it I would have committed a boundary
  assertion that proved nothing, for the third session running.
