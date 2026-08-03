---
topic: macOS typing lag root-caused to Emacs's Cocoa event loop, the input bridge round trip removed and measured, reviewed and pushed
date: 2026-08-02
status: Branch divert-input-past-the-bridge at 7897a1b, pushed, 134 tests green, two code-critic passes and a human review closed with no comments
Recurring-friction: passing-test-without-teeth
---

# Handoff: input no longer round-trips through the bridge, and the change survived review

Typing in a herdr terminal buffer felt laggy under macOS and fine under Linux.
The cause turned out to have nothing to do with herdr's frame stream, the
protocol, or the renderer. It is that GNU Emacs 30.2's NS build wakes a process
filter through the Cocoa event loop, and `herdr-term` crossed that boundary
twice per keystroke where a plain ghostel terminal crosses it once.

I measured the wakeup three ways on one machine, sending stamped lines from a
child and stamping arrival in the filter:

| Emacs | p50 | p90 |
| --- | --- | --- |
| Roman's live daemon, NS GUI frame | 9.7 ms | 12.5 ms |
| `-Q` daemon, no GUI frame | 1.5 ms | 5.7 ms |
| the same `-Q` daemon after adding an NS frame | 38 ms | 80 ms |

The third row was an unfocused frame, which is why it is so much worse than the
first; the point of the pair is that adding a GUI frame to an otherwise
identical daemon is what introduces the cost. Linux pays a fraction of a
millisecond for the same hop, which is the whole of the platform difference.

## Where the two hops were

`herdr-term--ensure-input-bridge` set `ghostel--process` to a `cat` subprocess,
and ghostel's module wrote keystroke bytes to it. `cat` echoed them back, Emacs
woke — hop one — and the filter then encoded them as a `terminal.input` command
on the control stream. herdr replayed them to the pane, the program repainted,
a frame arrived, and Emacs woke again — hop two — to paint it.

The bridge existed for a good reason: ghostel's module encodes backspace,
arrows and function keys internally and writes them itself, so rebinding keys
cannot cover every input path. `herdr-term--ensure-input-bridge`'s docstring
went one step further and asserted those writes "cannot be intercepted by
advising a send function". That claim was false, and disproving it is what
unlocked the fix. The module names `process-send-string` as a Lisp symbol, so it
calls the function rather than a C internal. Under advice, all three paths were
caught: a plain `"a"`, `backspace` as `\x7f`, and `up` as `\e[A`.

## The change

`herdr-term--divert-input` advises `process-send-string`. It recognises a bridge
by a `herdr-term-input-buffer` process property, and when it sees one it calls
`herdr-term--send-input` in the owning buffer instead of letting the bytes enter
the pipe. Every other caller falls through untouched.

The `cat` bridge stays live. ghostel requires a process in `ghostel--process`,
and keeping the bridge means correctness does not depend on my enumeration of
the module's write paths being complete: anything that reaches the pipe still
works, just slowly.

An A/B run in a throwaway GUI daemon, both arms using a real `cat` bridge and
sending one byte per timer tick so that Emacs idled between samples:

| Arm | n | p50 | p90 | max |
| --- | --- | --- | --- | --- |
| bridge, as it was | 15 of 30 | 2.5 ms | 10.7 ms | 20.2 ms |
| diverted | 30 of 30 | 0.011 ms | 0.42 ms | 1.79 ms |

Two caveats on that table. The bridge arm recorded only 15 of its 30 sends,
which I did not chase down — the harness drops a sample when a second byte
arrives before the first is stamped, so `cat` batching two ticks into one
wakeup would explain it, and so would a tick landing late. And 2.5 ms is the
bridge cost in a bare `-Q` daemon; the same harness in Roman's live daemon,
which carries packages and timers, measured p50 11.7 ms and p90 34.6 ms. The
diverted arm is synchronous, so its number does not depend on which daemon runs
it.

## What review changed

Two `code-critic` passes ran over the diff. Three findings were real and are
fixed in the commit:

The advice was installed on every full frame and never removed. Its lifetime is
not per-buffer, so pretending otherwise was the bug: an Emacs that had closed
every herdr buffer went on filtering every `process-send-string` any package
made. `herdr-term--kill-input-bridge` now retires it once
`herdr-term--input-bridge-live-p` finds no buffer holding a live bridge.

A signal raised while forwarding disappeared. ghostel 0.48's `ptyWrite` reads
the non-local exit after calling `process-send-string` and clears everything but
`quit`, so a failure inside the advice lost the keystroke with no message and no
backtrace — an observability regression against the old filter, where Emacs
reports filter errors. The diverted branch is now wrapped in
`with-demoted-errors`. The pass-through branch deliberately is not: it carries
every other `process-send-string` in the session, and demoting there would
swallow errors TRAMP and comint depend on.

The tests uninstalled the advice from whatever Emacs ran them. Their restore was
one-directional — it removed the advice when it had been absent, and did nothing
when it had been present — so running the suite in a live session left that
session unadvised, with typing quietly back to 12 ms and nothing to report it.
`herdr-term-test-restore-advice` now puts back the state it found.

**One finding I rejected after measuring it.** The second pass argued that a
diverted write can block on the control-stream pipe, that a blocked send pumps
the event loop, and that a device report raised by the repaint would then land
inside the half-written JSON line — and it recommended a re-entrancy guard,
which I had already written. Emacs keeps a per-process write queue: on `EAGAIN`
the remainder goes to the front, a nested send appends to the back, and the
queue drains in order. I wrote a harness that blocks a 300 KB line and fires a
nested send from a timer during the block. The nested payload landed at offset
300002, after the whole outer line. The guard came back out.

Two other recommendations I declined. Replacing `cat` with `make-pipe-process`
would save a fork per pane, but a pipe process does not echo what is written to
it, so the fallback would silently deliver nothing. And a large paste now
crosses as one long JSON line rather than being chunked by the pipe; herdr reads
its NDJSON with `stdin.lock().lines()` (`src/client/mod.rs:886`), which has no
length bound, so nothing needs to change.

## Facts worth keeping

- **`accept-process-output` hides the effect being measured.** My first
  round-trip benchmark polled and reported 0.21 ms for the same hop that costs
  11.7 ms when Emacs idles in its event loop — a 55-fold understatement that
  briefly ruled out the real cause. Latency through a process filter has to be
  driven from a timer.
- **An elisp scratch file without a `lexical-binding` cookie fails silently in
  a timer.** `load` gave the harness dynamic binding, so the closure's counter
  was unbound by the time the timer fired and the run produced no samples and
  no visible error.
- **herdr itself is upstream.** The flake pins `herdrdev/herdr`, not Roman's
  repo, and `herdr terminal session control` takes only `--takeover`, `--rows`
  and `--cols`. An earlier plan to add a raw-input subcommand and point
  `ghostel--process` straight at it therefore needed upstream work; the advice
  replaces it inside herdr.el.
- **`ghostel--redraw-now` is not the bottleneck.** A forced redraw of a live
  43×167 herdr buffer measured 1.6 ms, delta frames were 113 bytes at the
  median, and the stream had zero reconnects at seq 4591. Coalescing the paint
  is a throughput question, not a typing-latency one.
- **The existing `herdr-term-with-test-buffer` fixture stubs
  `process-send-string` with `cl-letf`,** which swaps the advised function cell
  wholesale and makes the advice inert inside it. The diversion tests need their
  own fixture, `herdr-term-with-test-bridge`, and the old tests are unaffected by
  the change for the same reason.
- **`advice-add` is idempotent by nadvice's contract** — it removes an identical
  advice before adding one. A test that adds twice and removes once proves
  nothing about the code under test.

## Current state

One commit, `7897a1b`, on `divert-input-past-the-bridge`, pushed. It touches
`herdr-term.el` and `test/herdr-term-tests.el` only. It replaces the two commits
the branch previously carried, which the review skill's collapse squashed once
the review closed; `refs/reviews/4` was moved onto it.

`just check` passes: every file byte-compiles under `byte-compile-error-on-warn`
with no warnings, all 134 ERT tests pass, and `check-declare` and `checkdoc` are
silent. Both new tests were mutation-checked — removing the demotion fails
`reports-a-failed-send`, and removing the retirement fails
`retires-the-last-divert`.

Roman read the change in a herdr review and closed it with no comments.

## Next steps

- Confirm the fix by feel in a real macOS pane. Every number here came from a
  harness, and the machine that felt the lag is not the machine that measured
  the fix.
- Open the PR when the branch is ready to land.

## Gaps

- **Hop two is untouched and is the floor.** The frame still arrives over a pipe
  Emacs must be woken to read, which is the one wakeup a plain ghostel terminal
  also pays. Going below it needs a protocol change on the herdr side.
- **No test drives a real module key encode.** The suite proves the advice
  intercepts a Lisp `process-send-string`; it cannot prove ghostel still reaches
  input that way. If a future ghostel switches to the C environment directly or
  to a native process, input keeps working through the bridge and only the
  latency returns — a mute failure, and the price of keeping the fallback.
- **`herdr-term--note-resize` signals "Window is on a different frame"** on
  window-size changes, muted by `safe_call` and visible in `*Messages*`. It
  costs no latency and was left alone.
- **`herdr-term--update-mode-line` calls `force-mode-line-update` per frame** to
  show a `seq` nobody reads mid-stream.
- **macOS-only options were not tried:** the Mitsuharu `emacs-macport`, whose
  select implementation differs, and `NSAppSleepDisabled`, given how much worse
  the unfocused frame measured.

## Skills and meta

- **Skills used.** `elisp-development` for the file's conventions and the
  compile/checkdoc gate; `herdr:review` to open the review and collapse the
  rounds afterwards; `writing:handoff` here.
- **Steering.** Roman asked whether the proposed fixes were actually known to
  work, which is what turned a plausible list into a tested one. Two items did
  not survive: the raw-input subcommand, which needed an upstream repo I had
  claimed was Roman's, and paint coalescing, which I had sold as a latency fix
  and is worth 1.6 ms. Proposing a fix and measuring it are different acts, and
  the first had been presented as though it were the second.
- **Steering.** `code-critic`'s two passes contradicted each other on the
  re-entrancy question, and the second was confident and specific enough to be
  convincing. Only the harness settled it. A review finding about runtime
  behaviour is a hypothesis with a citation, not a result, and the fix it
  recommends can be more dangerous than the bug it claims: the guard would have
  routed device reports through a pipe that `delete-process` can discard.
- **Meta.** The test that motivated `Recurring-friction: passing-test-without-teeth`
  again was `(should (null herdr-term-test-piped))` against a `make-pipe-process`
  bridge, which never echoes anything to its own filter. The assertion could not
  fail. The fixture now drives a real `cat` and the test asserts the unadvised
  write does reach the pipe before asserting the advised one does not — a
  negative assertion needs its positive control in the same test.
- **Meta.** I returned an empty turn mid-task after an edit and stalled until
  Roman asked what had happened. The work was intact; nothing had run. A turn
  that produces no tool call and no prose is a dropped thread, not a pause.
