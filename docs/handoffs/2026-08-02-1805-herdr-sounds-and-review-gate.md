---
topic: herdr.el plays herdr's notification sounds and lost two terminal bugs; herdr-review counts what it shows, has a flake gate, and no longer opens empty
date: 2026-08-02
status: Merged — herdr.el master at ad3d4fc and herdr-review main at fb2c032, both pushed, 125 and 29 tests green
Recurring-friction: passing-test-without-teeth
---

# Handoff: sounds landed in herdr.el, and herdr-review learned to measure itself

The session began as a survey of what was queued and ended with seven commits
across two repositories. Three of them fixed bugs that had never worked at all
rather than regressions — a resize hook that errored on every call, a review
summary that counted the wrong files, and a first review that was empty by
construction.

## herdr-review counts the review it opened

`changed_summary` built the panel row's summary from `git status --porcelain`
whatever the review was opened on, so `herdr-review open -- -r HEAD~3..HEAD`
reported a count of uncommitted files: a number about work nobody had asked to
look at. It now asks git about the same selectors tuicr was given.

Three things fell out of that which were not obvious going in.

`git status --porcelain` C-quotes a path containing a space, and
`git diff --name-only` and `git ls-files` print the same path plain. Counting
the working tree out of porcelain and a range out of diff therefore saw one
file under two names and counted it twice. Dropping porcelain entirely —
`diff --name-only HEAD` for tracked changes plus `ls-files --others` for
untracked — made every source agree.

`git ls-files` answers about the current directory, both in what it lists and
in how it prints it, so `-A` from a subdirectory counted the subtree and named
its members relative to there. `--full-name -- :/` fixes both halves.

A git command that fails is not a review with nothing in it. An unresolvable
range, a directory outside a repository, and a malformed `-r` all answered
zero, which reads on the row as "nothing to review". The count is now left
unsaid instead.

## The first review of any repository was empty

Opening a review of this session's own work produced a tab that closed itself
immediately, while `open` had already printed success. With no `refs/reviews`
marker to start from, `unreviewed_args` fell back to `--working-tree` alone,
and the work was committed — so tuicr was handed nothing, quit, and its exit
trap took the tab away.

That is worse than it sounds, because the skill instructs the operator to
commit before asking for a review. Following the instructions was what
produced the empty review.

A branch with no marker is now measured against its branch point: the
merge-base with the default branch, not its tip. The merge base is
load-bearing rather than pedantic, because the range is read as a diff —
against the tip, every file the default branch gained since the cut would
reach the reviewer as a deletion.

The marker rule needed tightening at the same time. `refs/reviews` lives in
the common git directory, so it is shared by every branch and every linked
worktree of a repository. Taking the marker whenever one existed meant a
branch that had never been reviewed picked up a marker left on a different
branch, and showed that branch's work as a deletion — a wrong non-empty
review, which is harder to notice than an empty one. A marker is now used
only where it is an ancestor of `HEAD`.

`open` also reports `summary` and `empty` now, so a caller cannot report a
review waiting that has already gone.

## A flake, and what the sandbox found

`just lint` ran shellcheck only where somebody had already installed it and
otherwise parsed each script and said so. herdr-review now has the same
flake-parts and nixDir layout as herdr.el: a dev shell carrying shellcheck,
jq, git and just, a pre-commit hook, and `nix flake check`.

The first cut declared `checks` and left it empty, so `nix flake check`
reported success having linted nothing and run no test. Wiring the real gate
in — nixDir has no checks kind, so it is a `perSystem` block by hand — then
found two portability defects that pass in every shell:

- A justfile recipe with a shebang runs through `/usr/bin/env`, which does not
  exist in a nix build. The lint loop moved out of the justfile into
  `test/lint`, which now finds every executable under `bin/` and `test/`
  rather than naming four files.
- The race test writes an `on-claim` hook with `#!/usr/bin/env bash`. It never
  ran in the sandbox, so the one test covering the claim race passed while
  testing nothing. It names the bash running the suite now.

## Two terminal bugs in herdr.el, both live in the daemon

Roman labelled a broken buffer in the running Emacs and pointed at
`*Messages*`. It held two unrelated faults.

**Every window resize errored, and no pane had ever been auto-fitted.**
`herdr-term--note-resize` is registered buffer-locally on
`window-size-change-functions`. Emacs hands a buffer-local entry the *window*
that changed and only a global entry the frame. The function read it as a
frame and passed it to `window-list` as the FRAME argument, which compares it
against the selected window's frame and signals "Window is on a different
frame". Confirmed against the live daemon before changing anything: a
buffer-local entry received `:windowp t :framep nil`.

**A pane herdr no longer has was retried as a dropped stream.** Quitting a
review closes its tab, so the pane goes; the buffer then spent three connect
attempts on a target that cannot come back, marked itself `dead`, and offered
a resync that would fail the same way. It now recognises herdr's own answer
and stops, and `herdr-term-pane-gone-action` says whether the buffer is killed
or kept marked `closed`.

Detection is a match on the reason string, which Roman chose over consulting
the session tree or asking the server — the alternative is a synchronous
request from inside a process sentinel, which hangs Emacs. `code-critic` read
herdr's Rust source to check the match: of the eleven reasons
`terminal.closed` can carry, exactly three end in "not found" and all three
mean the target does not resolve. The near misses end in `; retry`, `taken
over` and `detached`. A test over the three literal strings pins the coupling,
so a rewording upstream fails the suite rather than silently restoring the
retry loop.

The kill/keep condition Roman asked for — kill on a clean exit, keep when the
stream died mid-frame — was dropped and the option shipped as `kill` or
`keep`. With reason-matching detection, "the pane is gone" is only ever known
from herdr's own goodbye, so the clean-exit test could never be false and the
branch could never run.

## Sounds, and the decision herdr had already made

`herdr-sound-mode` rings when an agent starts waiting and again when one
finishes work you were not watching. The division of labour is herdr's:
its headless server decides that a state changed and forwards a notification,
and each connected client makes the noise. The server plays nothing itself, so
an Emacs that never attaches a herdr terminal had been silent.

The design changed once during the session, on a finding worth keeping. The
first version treated a move from working to idle as "finished". It is not.
`done` and `idle` are one internal state split by a `seen` flag
(`agent_view.rs:393`), and herdr writes that flag from its own suppression
decision (`actions.rs:3081`). So `done` is the finish herdr wants announced
and `idle` is the one it has already discounted — deriving the transition here
would have rung for precisely the finishes herdr chose to silence.

A finish is dropped again when the pane is on screen in Emacs, which is a
second and independent suppression. That is deliberate, and the commentary
says so rather than claiming to follow herdr throughout: the question worth
asking from Emacs is whether you can see the pane from Emacs.

## Facts worth keeping

Established by experiment or by reading source, and not recoverable from the
code that resulted.

- **A buffer-local `window-size-change-functions` entry is handed the window;
  a global one is handed the frame.** Verified in the live daemon. Reading the
  window as a frame reaches `window-list` as its FRAME argument, which signals
  "Window is on a different frame" rather than a type error.
- **`process-live-p` is Lisp in Emacs 30.2 and calls `process-status`.** A
  `cl-letf` stub of `process-status` that answers for every process therefore
  makes every process look dead. That silently walked a teardown past the
  input bridge it was meant to kill, and cost an hour.
- **A deleted `make-pipe-process` reports `closed`,** where a real subprocess
  reports `exit`. A sentinel that acts on `exit` cannot be driven by a pipe
  process without saying so.
- **herdr's sound assets are `include_bytes!`-embedded** and the nix package
  ships `bin` only, so there is no file on disk to point at. herdr writes the
  bytes to a temp file to play them.
- **Never bare `aplay`.** `src/sound.rs:300` carries the warning: it does not
  decode mp3 and plays the bytes as raw PCM.
- **`refs/reviews` lives in the common git directory,** so a marker is shared
  by every branch and every linked worktree of the repository.
- **`origin/HEAD` is set by `git clone` and by nothing else** — not by
  `git remote add` plus a fetch. A repository that started local has none.
- **There is no `/usr/bin/env` in a nix build sandbox.**

## Current state

`herdr.el` master is at `ad3d4fc` and pushed; 125 tests, `nix develop --command
just check` green. `herdr-review` main is at `fb2c032` and pushed; 29 tests,
`nix flake check` and the dev-shell gate both green.

Every commit went through a herdr review round and came back approved.

## Next steps

- Add tabs-to-workspace functionality, with a keybinding to rename them.
- Add dedicated commands to jump to the spaces and agents buffers.
- Write a skill mirroring the herdr one but with an Emacs backend, driving
  `emacsclient`.
- Exempt `blocked` and `done` from the dim on an unopened panel entry.
- `herdr-panel-unopened` and `herdr-panel-detail` resolve to one grey under
  two names.
- Add the `just reload` recipe that unbinds the `defvar` family, offered and
  declined two sessions ago.

## Gaps

- **`on` and `default` in `herdr-sound-agents` are inert.** Both mean heard,
  and only `off` does anything. They mirror herdr's own enum, which is the
  reason they exist, but it is configuration with no behaviour behind it.
- **A review of `--file` or `-p` is not counted.** Those selectors involve no
  history git can measure, so the row reads `review waiting` rather than a
  number. Correct, but it means a path-filtered review never gets a count.
- **The Darwin branch of the home-manager module is still unverified,** as it
  was two sessions ago. No darwin configuration exists to evaluate it against.
- **herdr-review's flake exports no overlay.** `packages.herdr-review-check`
  runs `just check` against the caller's cwd with no source pinned, which is
  right as a hook entry and odd as a published package.

## Skills and meta

- **Skills used.** `elisp-development` for every `.el` file, including its
  checkdoc gate, which caught four docstring faults. `herdr:review` for six
  review rounds across two repositories. `writing:handoff` here.
- **Steering.** `code-critic` ran four times and was worth it every time. On
  herdr-review it found the dedup claim was false for any path git quotes and
  proved it. On the flake it found `nix flake check` was reporting success
  having run nothing. On the branch-point fix it found the repo-global marker
  bug, which was worse than the bug being fixed. On the sound module it found
  the `done`/`idle` semantics that changed the design. **A critic that reads
  the dependency's source rather than reasoning about it finds a different
  class of defect.**
- **Steering.** `code-critic` also produced two findings that were taken as
  written but were wrong on a detail: it asserted `process-live-p` is a subr in
  Emacs 30.2 and unaffected by a `process-status` stub, and it read the
  `herdr-term--pane` `boundp` guard as a bug when it is the established and
  correct pattern. Both were caught by running the code. **Verify a critic's
  claim about runtime behaviour the same way you would verify your own.**
- **Meta.** Three tests written this session passed without testing anything,
  each found by mutation rather than by reading: a default-branch test where
  `main` and `trunk` pointed at the same commit, a player-order test with only
  one player installed, and a frame-handling test that passed before its fix
  existed. **A test written alongside the fix needs the fix removed before it
  can be believed.**
- **Meta.** The herdr-sound suite passed only because a sibling suite loaded
  `herdr-term` first; alone, the function under test returned nil for every
  input. Cross-file load order in a glob-loaded suite hides this. Requiring
  the dependency outright and running the one suite in isolation is the check.
- **Meta.** The Bash tool's working directory persists across calls. Reading
  herdr's Rust source left the shell in that checkout, and a later `just check`
  ran herdr's own CI — a Rust test suite — instead of herdr.el's. Prefix with
  an explicit `cd` when a session reads more than one repository.

## Addendum: key files

- `herdr-sound.el` — the mode, the transition rule, the per-agent table, and
  the player list. Not loaded with the package.
- `herdr-term.el` — `herdr-term--note-resize` takes a window;
  `herdr-term--pane-gone-regexp` and `herdr-term--end-for-good` are the
  vanished-pane path; `herdr-term-pane-gone-action` is the option.
- `~/Projects/oss/herdr-review/bin/herdr-review` — `review_start` is the
  marker-or-branch-point rule, `review_files` the counting.
- `~/Projects/oss/herdr-review/nix/checks.nix` — the gate as something
  `nix flake check` runs, wired up by hand because nixDir has no checks kind.
- `~/Projects/oss/herdr-review/test/lint` — the lint loop, moved out of the
  justfile so a nix build can run it.
