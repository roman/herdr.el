---
topic: herdr.el porcelain works end to end — terminal, JSON API client, and the three-panel UI
date: 2026-08-01
status: Working — 68 tests green, all committed, four features queued for next session
Recurring-friction: elisp-defvar-family-not-reassigned-on-reload
---

# Handoff: herdr.el renders herdr's UI in Emacs, driven by the JSON API

The previous session ended blocked: writable terminals rendered nothing. That
blocker was ours, not herdr's, and fixing it opened the way to everything else.
This session took herdr.el from one half-working terminal module to a porcelain
that mirrors herdr's own interface — spaces and agents panels beside a live
terminal, all driven by the public JSON API. Twenty-eight commits, 68 tests, and
`just check` green.

## The blocker, and what it actually was

`control` streams appeared to deliver no frames. They deliver frames fine.
`ghostel--init-buffer` refuses to run while `ghostel--process` holds a live
process, and on a writable buffer that slot holds our `cat` input bridge. So
every full frame failed to apply, triggered a reconnect, and looped. Read-only
buffers have no bridge, which is why `observe` always looked healthy.

The old "resync suppressed … too soon" logic then dropped the recovery, so the
symptom presented as a dead stream rather than a loop. The fix shadows
`ghostel--process` across the reset rather than tearing the bridge down, because
the bridge's unflushed bytes are keystrokes the user already typed.

Two more defects surfaced in the same area, both confirmed by experiment rather
than reasoning:

- **Stray writes corrupted the wire.** `:buffer buffer` on the stream process
  made it the buffer's process. `ghostel--write-pty` with a nil `ghostel--process`
  calls `process-send-string` with nil, which Emacs resolves to that process — so
  a stray keypress wrote raw bytes into a stream that speaks JSON. The stream now
  has no buffer and carries its own on the process plist.
- **Silent grid divergence.** `ghostel--adjust-size` acts whenever
  `ghostel--process` is live, which the bridge made true. It would resize the
  grid to the Emacs window while herdr kept sending frames sized for its own, and
  no `seq` gap marks that. We disowned it, and later replaced it with
  `terminal.resize`.

## What we built

**`herdr-api.el`** — a client for herdr's public JSON socket. Five public
functions, no method names, no UI. Three protocol facts shape it, each confirmed
against a running 0.7.5 rather than taken from documentation:

- The server answers one request per connection and closes it. There is no
  multiplexing and nothing to correlate.
- `params` is mandatory, including for methods that define none.
- `events.subscribe` holds its connection open. Subscriptions are tagged objects;
  the events returned rename the subscription's dots to underscores.

`docs/baseline.md` described a multiplexed socket with `id` correlation. That is
wrong and we corrected the document, because a client built to it would carry a
correlation layer with nothing to correlate.

**`herdr-session.el`** — one copy of the session tree, kept current, that every
panel reads. It re-snapshots rather than patching from events, because only the
lifecycle events carry whole nodes and the agent list has no event at all. A
fingerprint over just the fields a panel draws decides whether to announce a
change; without it a working agent's `pane.updated` churn cost about eighteen
redraws for one workspace being created.

**`herdr-panel.el`, `herdr-agents.el`, `herdr-spaces.el`, `herdr-ui.el`** — the
three-panel layout. `M-x herdr-ui` puts spaces above agents down the left, sixty
to forty, with a terminal filling the rest; `C-c C-b` toggles the column. Entries
are multi-line and follow herdr's own default token layout, with per-field
colours and a dim that goes *over* a closed entry so it recedes whole.

**Terminal work** — scrolling through pane history (`terminal.scroll`, bound to
evil motions and the shifted page keys), taking control of an observed pane, and
fitting the pane to its window.

## Facts about herdr worth keeping

These cost real time to establish and are not written down anywhere else.

- **herdr emits no event when a pane's working directory changes.** Driving a
  `cd` while logging the stream produced 213 events, every one about focus, while
  the workspace label changed from `zoo.nix` to `herdr` on the server. Workspace
  labels are *derived* from the root pane's cwd, so a client listening only to
  events shows the directory a workspace started in forever. `herdr-session` polls
  every five seconds as a backstop.
- **Branch and git status are not on the wire.** herdr computes both and shows
  them on a space, but `WorkspaceInfo` carries no such field; the only `branch`
  in the API is on `WorktreeInfo`, via `worktree.list`, for worktrees only. We ask
  git directly instead.
- **Scroll position and pane size are per-pane, not per-client.** Scrolling or
  resizing from Emacs moves the pane for every client, the herdr terminal
  included. `terminal.scroll` is a `control` command, so an observing buffer
  cannot scroll at all.
- **`events.subscribe` replays a backlog on connect.** Harmless here — a stale
  event triggers a snapshot the fingerprint discards — but it means the stream is
  not purely live, which matters to anyone building incremental patching on it.
- **Nerd Fonts has no Claude glyph**, and neither does `nerd-icons`. The default
  is `✳`, the mark Claude Code puts in its own terminal title.

## Current state

Everything is committed on `master`; the tree is clean and `just check` exits 0.
The repo has no remote, and all history is direct to `master`.

Modules: `herdr-api.el`, `herdr-session.el`, `herdr-panel.el`, `herdr-agents.el`,
`herdr-spaces.el`, `herdr-term.el`, `herdr-ui.el`, with tests for the first two
and the terminal. `just check` byte-compiles with warnings as errors, runs
`check-declare` and checkdoc over source and tests, then the ERT suites.

The panels and a terminal are live in the running Emacs daemon.

## Next steps

- Add tabs-to-workspace functionality, with a keybinding to rename them.
- Add dedicated commands to jump to the spaces and agents buffers.
- Investigate playing a sound when a session asks for attention, as herdr does.
- Write a skill mirroring the herdr one but with an Emacs backend, driving
  `emacsclient`.

## Gaps

- **Space grouping has never met real data.** Workspaces sharing a repository
  render as a collapsible group; four unit tests cover it, but no workspace in
  this session had `worktree` info, so it has only ever rendered flat.
- **The status mark dims on a closed entry**, which was asked for literally but
  means a blocked agent in an unopened pane whispers rather than shouts.
  Exempting `blocked` and `done` is a two-line change.
- **`herdr-panel-unopened` and `herdr-panel-detail` resolve to the same grey.**
  Fine today because a closed entry dims uniformly, but they are two names for
  one colour.

## Skills and meta

- **Skills used.** `elisp-development` — tarsius conventions, file template and
  the compile/checkdoc gate; every module follows it. `tuicr` — user-led review
  of the committed diff, driven through a herdr pane. `code-critic` — reviewed
  `herdr-term.el` and then the API split; found the event-filter reordering, the
  refused-subscription hole and the missing disconnect signal, all three real and
  all three fixed.
- **Steering.** code-critic proposed deleting `herdr-api-panes` and
  `herdr-api-read-pane` from the transport module. We took it: they moved back to
  `herdr-term.el`, which also restored a message the split had lost — "no live
  panes" had become an API error rather than an ordinary empty state. Separately
  it flagged `herdr-api-request`'s synchronous design as a risk; we kept it, since
  the protocol is one-shot, and documented the real hazard instead (a process
  filter runs with quitting inhibited, so a callback that calls it freezes Emacs).
- **Meta.** Mutation testing earned its place: every fix was verified by reverting
  it and confirming exactly one test failed. Two "passing" suites turned out to
  have no teeth until the stub was made faithful to ghostel's real refusal.
- **Meta.** Reading herdr's Rust source for exact values beat guessing every
  time — the status glyphs, the Catppuccin palette, the default sidebar token
  rows and the `terminal.scroll` semantics all came from source, not inference.

## Addendum: the reload footgun

`defvar`, `defcustom`, `defvar-keymap` and `defface` all leave an existing
definition alone on reload. This bit four times in one session — a stale keymap
made new bindings invisible, stale ASCII marks survived a glyph change, and a
stale face spec kept a red highlight after the spec said grey. A plain
`load-file` is not enough:

```elisp
(dolist (symbol '(herdr-panel-status-symbols herdr-term-command-mode-map))
  (makunbound symbol))
(dolist (face '(herdr-panel-current herdr-panel-path))
  (put face 'face-defface-spec nil))
```

A `just reload` recipe doing this properly was offered and declined; it is still
worth having.

## Addendum: key files

- `docs/baseline.md` — architecture spec, corrected in this session. Plane 1 now
  describes the socket as one request per connection, says which events carry a
  whole node and which only identifiers, and records the three gaps: no event
  for a working directory change, no branch or git status on the wire, and a
  backlog replayed on subscribe.
- `herdr-api.el` — socket transport, three error conditions, event subscription.
- `herdr-session.el` — the tree, the fingerprint, the poll, and
  `herdr-session-fingerprint-functions` for panels showing what the tree does not
  carry.
- `herdr-panel.el` — faces, row rendering, section-wise navigation, and the
  `beneath`/`over` face-merge order that makes dimming work.
- `justfile` — `just check` is the gate; `_load-path` resolves ghostel and
  magit-section through `emacs -Q` plus `package-initialize`.
