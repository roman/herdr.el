---
topic: herdr.el terminal plane — input solved, blocked on control-stream frame delivery
date: 2026-08-01
status: Blocked — terminals do not render; input layer is solid
Recurring-friction: herdr-control-stream-no-frames
---

# Handoff: herdr.el terminal plane works for input, blocked on `control` frames

We built the terminal layer of `herdr.el` — an Emacs porcelain that renders and
drives herdr-owned panes. Input is fully working after a long debugging arc. The
blocker is that the herdr `control` stream stops delivering output frames to the
Emacs client, so the terminal buffer renders nothing. Rendering fidelity, input,
and the surrounding machinery are all proven; only the output transport is broken.

## What the project is

The goal is a herdr-in-Emacs porcelain: wrap the running herdr server rather than
reimplement it. The design spec is `docs/baseline.md` — read it first. Core ideas
we confirmed and built on:

- herdr runs its own multiplexer (vendored `portable-pty` + `libghostty-vt`); the
  server owns PTYs, thin clients attach. No tmux.
- herdr exposes two sockets: a **public JSON API** (`~/.config/herdr/herdr.sock`,
  newline-JSON, supported) and a **private binary client socket** (frame protocol,
  `PROTOCOL_VERSION`). We build on the JSON API plus the CLI bridges, never the
  binary socket.
- **ghostel** (`dakra/ghostel`, on MELPA) is the renderer: an Emacs terminal
  emulator on the same `libghostty-vt`. Its module decouples the VT from the PTY —
  `ghostel--new` makes a term with no process, `ghostel--write-vt` feeds it bytes,
  `ghostel--redraw-now` paints. This is why we can render herdr's byte stream with
  full fidelity (verified: 24-bit color, attributes, box-drawing, CJK, emoji).

## What we accomplished

**`herdr-term.el`** (the terminal module) does the following, all verified working
except output frame delivery:

- Renders a pane by streaming `herdr terminal session observe|control` frames
  (base64 ANSI) into a ghostel buffer.
- Handles the frame protocol: one `full:true` frame on connect (authoritative —
  we reset the ghostel term via `ghostel--init-buffer`), then `full:false` deltas
  with an incrementing `seq`. A `seq` gap or stream exit triggers a resync
  (reconnect, since herdr has no "request full frame" command).
- Recovers from the silent delta divergence across alt-screen apps (vim/top) that
  herdr's flattened stream causes — resync fixes it.
- Gives up after `herdr-term-max-connect-attempts` failed connects that never
  synced, so an invalid pane target does not loop forever.
- `herdr-term-open` completes live pane ids from `herdr pane list`; `herdr-term-new`
  creates a workspace and opens it writable — create-and-drive from Emacs.

**Input** was the hard part and is now solved. The final design: we set the
buffer-local `ghostel--process` to a `cat` process and forward its echoed stdout to
herdr's stream (`herdr-term--ensure-input-bridge`). ghostel and evil-ghostel drive
input natively — printable keys, evil passthrough (`C-a`/`C-e`), and the module key
encoder (backspace, arrows) all write to the PTY sink, which is now `cat`, which we
bridge to herdr. Confirmed: typing, `RET` submits, `C-a` moves to line start,
backspace deletes.

**Nix daemon** (in `~/Projects/self/zoo.nix`, uncommitted): added the `herdr` flake
input, `nix/modules/home-manager/herdr.nix` (systemd user service on Linux, launchd
agent on Darwin, freeform `zoo.herdr.settings` → `config.toml`), wired into
`all.nix`. The Linux branch is eval-validated against the `reiner` config; the
Darwin branch is written to spec but unverified (no darwin config to eval).

## The blocker

The `control` stream is not delivering output frames to the Emacs client. The
process connects, does not error (`herdr-term--close-reason` stays nil), but never
syncs — `herdr-term--last-seq` stays nil and the buffer is empty. So what looked
like "lag" is a **frozen buffer**, not slow rendering.

We ruled out the wrong suspects:

- **Not libghostty.** It is only the VT parser; identical on both ends.
- **Not transport speed.** `observe` does ~27 fps under continuous output
  (measured). The real herdr TUI feels instant because it uses the binary client
  socket's semantic-frame push; our CLI stream is slower but not the frozen-buffer
  cause.
- **`control` specifically is flaky.** Raw `herdr terminal session control <pane>`
  returns `{"reason":"detached"}` with zero frames (partly a stdin-EOF artifact of
  a CLI test with no stdin, but our live-stdin Emacs process also never gets
  frames). `observe` on the same pane returns frames fine.

The likely cause is one of: a herdr-side control behavior we do not understand, or
the server sitting in a bad state after the dozens of test `control` connections we
opened this session.

## Current state

- `herdr-term.el` is loaded in the running Emacs daemon but its control-based output
  is broken. A stale `*herdr:w7:p1*` buffer is open and frozen.
- herdr session `w1` (label "herdr") and `w7` (label "zoo.nix", the user's terminal)
  are the only live workspaces; all test panes cleaned up.
- Nothing is committed — `herdr.el` and all `zoo.nix` changes are working-tree only.
- The herdr server (systemd `herdr` service, v0.7.5) may be in a degraded state from
  heavy test connections.

## Next steps

1. Rearchitect the transport: `observe` for output + JSON-API `pane.send_text` for
   input, dropping `control` entirely. Verify `pane.send_text`/`send_input` accepts
   raw bytes (escape sequences, control chars) — may need a base64 `bytes` field.
2. If keeping `control`: investigate why it detaches / sends no frames to a
   live-stdin client. Try restarting the herdr server first to clear state (kills
   running panes — confirm with the user).
3. Reopen `w7:p1` once output works; it is currently frozen.
4. Commit the nix daemon module (`zoo.nix`) and `herdr-term.el` once the transport
   is settled.

## Skills and meta

- **Skills used.** `writing:author` — drafted `docs/baseline.md`. `code-critic` —
  reviewed `herdr-term.el`, found the read-only-keymap gap and the accidentally-safe
  post-resync line handling, both fixed. Explore agents — mapped herdr's
  architecture, doc feature set, and verified the exact JSON API / attach surface.
- **Meta.** Testing terminal input from a headless `emacsclient --eval` is
  unreliable: `execute-kbd-macro` does not dispatch through evil/ghostel in that
  context, and `sit-for` does not pump subprocess output. Ground truth came from
  real wall-clock `sleep` plus herdr-side `herdr pane read`. The `control` stream
  being unreliable as an interactive transport (see `Recurring-friction`) is the
  session's main external-tool lesson — the reliable primitives are `observe`
  (output) and `pane send-text`/`send-keys` (input).

## Addendum: key files

- `docs/baseline.md` — architecture spec; the frame protocol and mode-flattening
  findings are documented in its Plane 2 section.
- `herdr-term.el` — the terminal module. Input bridge, frame/seq state machine,
  resync, completion, `herdr-term-new`.
- `spike/herdr-spike.el` — the original throwaway spike that proved rendering.
- `~/Projects/self/zoo.nix/nix/modules/home-manager/herdr.nix`, `flake.nix`,
  `nix/modules/home-manager/all.nix` — the daemon module.
- ghostel source was cloned to the session scratchpad for reference (ephemeral);
  re-clone `https://github.com/dakra/ghostel` if needed. The input send path is
  `ghostel--send-string`/`ghostel--send-encoded` → `ghostel--write-pty` →
  `ghostel--process`; the encoder path writes to `ghostel--process` inside the
  module, which is why only the `cat`-bridge approach caught every key.
