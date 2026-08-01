# A herdr-in-Emacs baseline: the porcelain architecture

Do not port herdr. **Wrap it.** Run the real herdr server as the backend and
build the Emacs side as a porcelain over its public JSON API, exactly the way
magit is a porcelain over the `git` binary. herdr already owns the PTYs, the
terminal emulation, the multiplexing state, the persistence, and — the part that
matters most — the agent detection. None of that is worth reimplementing in
Elisp when a maintained server exposes it over a socket.

This keeps the property you liked. herdr's model is *the pane is a real terminal,
and agent-awareness is a detection layer on top*, so anything you run in a shell
gets tracked, not just protocol-speaking agents. A porcelain inherits that for
free: detection happens in the server, and Emacs just reads the verdict. Every
ACP/JSON-RPC Emacs package throws this away by binding to one agent protocol; the
porcelain does not.

herdr is also built for this. Its own guardrail says it is migrating toward "a
server-owned runtime protocol with the TUI as one client." An Emacs porcelain is
the second client.

---

## The one load-bearing fact: two sockets

herdr exposes **two separate sockets with two different wire formats.** Getting
this right is the whole architecture.

| Socket | Path | Wire format | Use it for |
| --- | --- | --- | --- |
| **JSON API** (public) | `~/.config/herdr/herdr.sock` (`HERDR_SOCKET_PATH`; named sessions under `sessions/<name>/herdr.sock`) | newline-delimited JSON, `{id, method, params}` → `{id, result\|error}` | Everything structural: the tree, agents, events, actions |
| **Client protocol** (private) | `~/.config/herdr/herdr-client.sock` | binary, 4-byte length-prefixed frames, `PROTOCOL_VERSION = 18` handshake | **Do not speak this.** It is the internal TUI/frame renderer |

The JSON API is the supported third-party surface — `socket-api.mdx` calls it out
for "custom tools, protocol clients, and event subscribers." No auth beyond file
permissions (both sockets are `0600` owner-only); you connect and send JSON. The
binary socket is marked internal in `src/protocol/wire.rs:1`. You reach the live
terminal *through a CLI bridge* (below), so you never implement the binary
protocol or track `PROTOCOL_VERSION` yourself.

Emacs speaks the JSON API natively: `make-network-process :family 'local :service
"~/.config/herdr/herdr.sock"`. Unix sockets, no subprocess needed for control.

---

## Plane 1 — Control: the dashboard, from the JSON API

A connection per request, plus one long-lived connection for the event stream.

An earlier draft of this section described a multiplexed socket where replies
are correlated by the `id` you send. That is wrong, and it matters, because it
invites a correlation layer for a protocol with nothing to correlate. What the
server actually does — read from `src/api/server.rs`, then confirmed against a
running 0.7.5 — is read a single request line per connection, write a single
reply line, and close. There is no read loop. `herdr-api-request` therefore
opens a connection, spends it and drops it.

Two more details the same exercise turned up, both of which bite on first
contact:

- `params` is mandatory, including for methods that define no parameters.
  Sending `{"id":…,"method":"ping"}` is an `invalid_request` error; it must be
  `{"id":…,"method":"ping","params":{}}`.
- The `id` still comes back on the reply, so it is worth checking, but a
  request the server could not parse is answered with an empty one.

`events.subscribe` is the exception that keeps its connection open; see below.

### Bootstrap the model

`session.snapshot` returns the entire tree in one call (`src/app/api/session.rs`):
`workspaces[]`, `tabs[]`, `panes[]`, `agents[]`, `layouts[]`, plus
`focused_workspace_id / focused_tab_id / focused_pane_id` and `protocol` (=18, gate
on it). Each node is rich enough to render directly:

- **`AgentInfo`**: `agent_status` (`idle`/`working`/`blocked`/`done`/`unknown`),
  `name` (user-assigned, or the pane id if unnamed), `agent` (detected kind —
  `claude`, `codex`…), `display_agent`, `pane_id/tab_id/workspace_id`, `tokens{}`,
  `agent_session`. This is your dashboard row, pre-computed.
- **`PaneInfo`**: `pane_id`, `terminal_id`, `agent?`, `agent_status`, `cwd`,
  `title`, `scroll{offset_from_bottom,…}`, `revision`.
- **`WorkspaceInfo` / `TabInfo`**: carry a rolled-up `agent_status` already. herdr
  does the rollup server-side — a blocked pane makes its tab and workspace read
  blocked. You do not compute it.

### Stay live with events

`events.subscribe {subscriptions:[…]}` acks, then pushes events on the same open
socket (`src/api/schema/events.rs`). Two shape details, both confirmed live:
subscriptions are tagged objects rather than names — `[{"type":"pane.updated"}]`,
not `["pane.updated"]` — and the events that come back rename the dots to
underscores, so subscribing to `pane.updated` delivers `{"event":"pane_updated",
"data":{…}}`. A refusal arrives on that same connection as an ordinary error
reply, which is easy to mistake for "not an event" and drop; do not, or the
client waits forever on a stream that will never carry one.

For a global dashboard, subscribe to the lifecycle and update events, which each
carry the full node:

- `pane.created` / `pane.updated` / `pane.closed` / `pane.focused` — `pane.updated`
  ships the whole `PaneInfo` including `agent_status`, so status changes arrive
  here globally.
- `pane.agent_detected {pane_id, agent?, released, final_status?}` — an agent
  appeared/left in a pane. Global.
- `workspace.*` and `tab.*` (created/updated/renamed/moved/reordered/closed/
  focused) — keep the tree in sync.

There is a dedicated `pane.agent_status_changed` event, but its subscription is
**per-pane** (`{pane_id, agent_status?}`). For a whole-session view, prefer the
global `pane.updated` / `pane.agent_detected` stream over re-subscribing per pane.

### The counter — you build this one

Correcting an earlier assumption: **global attention counts are not on the wire.**
The only attention total lives in herdr's own UI badge (`src/app/state.rs`), not
in the API, and `agent.view.set` explicitly "does not change global attention
counts." So the counter you liked is a client-side reduce over agent statuses from
the snapshot/events: `blocked` count, plus `done` (= idle work finished but not yet
seen). One function, recomputed on each event, surfaced in the mode-line or
tab-bar: `⛔2 ●3 ✓1`. Trivial, but yours to write.

(Skip `agent.view.set`/`agent.view.clear` — that filter/sort DSL only reshapes
herdr's *own* built-in Agents view, not `agent.list`. In Emacs you already have
the agent list; sort it in Elisp.)

### Render it

`magit-section` is the idiomatic build — a collapsible workspace → tab → pane/agent
tree with a state icon per row and jump-on-RET. This is what `emacs-gravity`
already does, and why it feels magit-like. Refresh on each event.

### Act on it

All actions are JSON calls: `pane.send_text {pane_id,text}`, `pane.send_keys
{pane_id,keys[]}`, `agent.start {kind,pane,…}`, `pane.focus`, `workspace.create`,
`worktree.create`. "Jump to next blocked agent" is a reduce over the model plus a
`pane.focus`.

---

## Plane 2 — Terminal: rendering a live pane in a buffer

The live terminal is the one thing the JSON API does not stream. herdr owns the
PTY, so Emacs cannot put a native `vterm` on the process — vterm and eat insist on
spawning and owning the child. You have a *stream*, not a process. The fix is
**ghostel**, and it is close to perfect for this.

### Why ghostel is the right renderer, not a compromise

ghostel is an Emacs terminal emulator (dynamic Zig module, MELPA, Emacs 28.1+)
built on **libghostty-vt — the same VT engine herdr vendors on the server.** So
the ANSI herdr produces is parsed by the identical engine on the client: true
color, the kitty keyboard and graphics protocols, and OSC-8 hyperlinks all survive
with no fidelity loss. `term.el` would mangle exactly those.

The decisive detail is that ghostel's module **decouples the VT from the PTY**
(`src/GhostelTerm.zig`):

- `ghostel--new ROWS COLS` creates a terminal object and **spawns no process** — it
  only initializes the renderer/grid state in the current buffer.
- `ghostel--write-vt TERM DATA` feeds raw bytes straight to the parser
  (`stream.nextSlice(data)`); `ghostel--redraw TERM` paints the grid. No PTY
  required.
- `ghostel--write-pty` and `ghostel--spawn-native-process` are the separate,
  opt-in path for when ghostel *does* own a child. You never call them here.

This is precisely the primitive Option B needs, and **ghostel already ships a
working example of it**: `ghostel-compile.el` renders an external compile stream
into a process-less ghostel grid via `ghostel--write-vt` + `ghostel--redraw-now`
(`lisp/ghostel-compile.el:363-367`). Copy that pattern.

### The wiring

Drive it through herdr's two CLI bridges (so you avoid the binary protocol):

- **Output:** `herdr terminal session observe <pane_id>` emits newline JSON on
  stdout — `{"type":"terminal.frame","seq":N,"encoding":"ansi","width":W,
  "height":H,"full":bool,"bytes":"<base64 ANSI>"}`. Base64-decode `bytes` →
  `ghostel--write-vt` → `ghostel--redraw`. Multiple observers per pane are allowed,
  so read-only previews cost nothing.
- **Input:** `herdr terminal session control <pane_id>` reads commands on stdin —
  `{"type":"terminal.input","text":…}` or `{"…","bytes":"<base64>"}`,
  `terminal.resize`, `terminal.scroll`, `terminal.release`. Translate Emacs key/
  mouse events into these. One controller per pane (`--takeover` to steal); control
  and observe coexist on the same pane.
- **Resize:** `ghostel--set-size` locally to match the buffer's window, and send
  `terminal.resize {cols,rows}` to herdr so the server-side PTY tracks it.

One wiring subtlety on input: ghostel's `ghostel--encode-key` / `--encode-paste`
produce the correct byte encodings (including kitty-keyboard), which is genuinely
useful, but they *also write to a PTY as a side effect* — and ghostel owns none
here. Take their returned bytes and forward them to herdr's `control` stream as
`bytes`; do not rely on their PTY write. Or sidestep encoding entirely and send
plain `text` for ordinary keys, reserving encoded `bytes` for special keys.

### Frame protocol and resync (validated by the spike)

The spike surfaced two protocol facts the naive version got wrong. Both are
non-negotiable for the real module.

**Frames are `full` then deltas.** herdr sends one `{"full":true}` frame on connect
(a complete repaint, the authoritative resync point) followed by `{"full":false}`
delta frames, each stamped with an incrementing `seq` and the current
`width`/`height`. Deltas are relative to the previous composed frame, so a client
that drops or misapplies one frame diverges permanently until the next full frame.
The module MUST: treat `full:true` as a grid reset before applying; track `seq` and,
on a gap, force a resync. There is no "request full frame" control command, so the
practical resync is a reconnect (a fresh connect always begins with a full frame) —
budget for that. herdr coalesces aggressively (a whole vim session produced ~9
frames), so deltas are chunky, not per-keystroke.

**herdr re-serializes; it does not pass raw app bytes.** The `TerminalAnsi` stream
is herdr's *own* libghostty-vt rendering of the pane, re-emitted as positioning +
cells wrapped in synchronized output — not the application's raw escape stream. Two
consequences the spike proved:

- Terminal *modes* are flattened. Running `vim` renders perfectly, but
  `ghostel--alt-screen-p` stays nil — the `?1049h/l` never reaches the client. Do
  not depend on ghostel's own mode state (alt-screen, mouse modes, bracketed
  paste); drive scroll/mouse through herdr `control` (`terminal.scroll`) instead.
- Because both ends run libghostty-vt, *content and style* fidelity is exact
  (verified: 24-bit color as `(:foreground "#ff0000")`, bold/underline/reverse,
  256-color backgrounds, box-drawing, CJK, emoji). That is the whole reason to use
  ghostel — but it does not make the two VT models bit-identical across mode
  transitions, which is exactly why the resync discipline above matters.

**Confirmed: deltas can diverge across alt-screen apps with no seq gap.** Running
`vim`/`top` and returning to the shell intermittently leaves the client's grid
wrong even though every frame arrived in order — herdr's alt-screen save/restore is
state the flattened stream does not fully hand over. seq-gap detection does not
catch this. Two things are required, both now implemented in `herdr-term.el`:

- A full frame (and every resync) must **reset the ghostel terminal**
  (`ghostel--init-buffer`), not just write bytes onto the existing grid — a reused
  grid keeps the drift. A fresh reset renders identically to a fresh open.
- Because nothing signals the divergence, recovery is **resync = reconnect**
  (fresh full frame). It fires automatically on a seq gap or stream exit, and
  manually on `C-c C-l`. Intentional teardowns must detach the process sentinel
  first, or the sentinel races a second reconnect that can blank the buffer.

Open question for the real module: auto-heal silent divergence without a manual
resync. Candidate triggers — resync when the pane's foreground process returns to
a shell (from the JSON-API `pane` events), or a periodic viewport-hash watchdog
against `pane read`. Neither is built yet.

### A trivial first spike

Before wiring observe→ghostel→control, you can prove the whole stack in an hour:
run `herdr terminal attach <pane_id>` inside a plain `vterm`/`eat`/ghostel buffer.
It is a full-screen raw-mode client — herdr renders, Emacs hosts. Detach with
`ctrl+b q`. It is one pane per buffer and single-writer, so it is a spike, not the
architecture, but it confirms the server and the pane ids before you build the real
renderer. Prefer ghostel as the host even here, for the same fidelity reason.

**Recommendation:** attach-in-a-buffer as a day-one spike; then build the real
terminal plane as **observe → `ghostel--write-vt` → control**. ghostel turns what I
first framed as the lossy fallback into the best path, and unlocks multiple live
panes and dashboard previews.

---

## What herdr gives you vs what you build

The build column is far smaller than a from-scratch port, and — critically — it no
longer includes detection.

| Concern | Source |
| --- | --- |
| PTY, VT emulation, multiplexing, persistence, restore | **herdr** (its server) |
| **Agent detection, states, rollup to tab/workspace** | **herdr** (`agent_status` on every node) — the fiddly part, done and maintained |
| Full session tree, live event stream | **herdr** — `session.snapshot` + `events.subscribe` |
| Actions (send text, spawn agent, focus, worktrees) | **herdr** — JSON methods |
| Live terminal frames | **herdr** — `terminal session observe/control` (or `attach`) |
| VT parsing / grid rendering in the buffer | **ghostel** — same libghostty-vt engine, `write-vt` feeds it |
| JSON-API socket client (network process, `id` correlation, event loop) | **build** |
| `magit-section` dashboard + refresh | **build** |
| **The attention counter** (client-side reduce) | **build** — not on the wire |
| Terminal buffer glue (observe → `ghostel--write-vt` → control) | **build** — pattern copied from `ghostel-compile.el` |
| Notifications | **build** — `alert.el` off the event stream |

---

## Honest caveats

- **You are coupled to the herdr binary.** The porcelain needs a running herdr
  server. That is the point, but it is a hard dependency, and the JSON API can add
  fields across versions — handle unknown fields gracefully and gate on the
  `protocol` value in `session.snapshot`.
- **Attach and observe/control are Unix-only.** Direct terminal attach returns
  `Unsupported` on Windows. Scope the terminal plane to Linux/macOS. The control
  plane (JSON API over a named pipe) would still work on Windows, but a dashboard
  with no live terminal is half a tool.
- **ghostel adds a native-module dependency.** It is a dynamic Zig module (it
  auto-downloads a prebuilt binary on first use, Emacs 28.1+). That is a heavier
  dependency than pure Elisp, but it buys the engine symmetry, and its
  `write-vt`/PTY split is what makes the observe path clean at all.
- **Input encoding has a side effect.** `ghostel--encode-key`/`--encode-paste`
  write to a PTY ghostel does not own here; use their return value and forward it
  to herdr's `control` stream, or send plain `text` for ordinary keys.
- **One writer per pane.** Both attach and `control` are single-owner. Fine for
  one human, but concurrent Emacs frames on the same pane need `--takeover`
  handoff logic.
- **The counter and the "seen" bit are yours.** `done` vs `idle` is herdr's unseen
  flag and it does flow through the API, but the aggregate counter does not — you
  own that reduce.

---

## Recommendation and MVP scope

Wrap, do not port — and prefer this over building on `emacs-gravity` or Magnus,
both of which plumb Claude-specific JSONL/`--print` rather than the run-anything
server. Borrow gravity's `magit-section` layout; drive it from herdr's API.

The MVP, in build order:

1. **JSON-API client** — a `make-network-process` connection to `herdr.sock`,
   `{id}` request/response, and a second connection running `events.subscribe`.
2. **Model + dashboard** — hydrate from `session.snapshot`, keep it live off the
   event stream, render with `magit-section`, add the client-side counter and
   jump-to-blocked.
3. **One live pane (spike)** — `herdr terminal attach <pane_id>` inside a ghostel
   buffer, to prove the server and pane ids end-to-end.
4. **The real terminal plane** — `observe → ghostel--write-vt → redraw` for output,
   Emacs key/mouse → `control` for input, modeled on `ghostel-compile.el`.
5. **Notifications** — `alert.el` on `blocked`/`done` transitions.

That is a working herdr porcelain in Emacs, and it is meaningfully less code than
the port — because the hard parts you cared about already run elsewhere: agent
detection in the herdr server, and VT rendering in ghostel, both on the same
libghostty-vt engine. What is left is glue over two supported sockets. Multi-pane
layouts and richer actions come after.
