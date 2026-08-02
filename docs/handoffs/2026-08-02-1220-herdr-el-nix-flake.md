---
topic: herdr.el builds and tests from a nix flake; ghostel comes from the unstable channel
date: 2026-08-02
status: Working — committed as ea96f5e, 68 tests green, four porcelain features still queued
Recurring-friction: nix-path-channel-mistaken-for-locked-input
---

# Handoff: herdr.el builds and tests from a flake, and a vendored package went away

The previous session left the porcelain working and four features queued. None
of them got touched. This session started with `just: command not found` and
turned into declaring the development environment properly: a flake on master,
two dev shells, a home-manager module for the herdr daemon, and a pre-commit
hook running the same gate.

Its main output was a deletion. We vendored a ghostel derivation, built it,
tested against it, and then removed it once we found nixpkgs already had one.

## The dependency assessment, and the mistake in it

We scanned the elisp for `require` forms, `declare-function`, and external
process calls, then reported that herdr.el needs Emacs 29.1+, `magit-section`,
`ghostel`, the `herdr` CLI, `git` for branch state, and `cat` for the input
bridge. That part held up.

The part that did not: we said `ghostel` was absent from nixpkgs and vendored
the derivation from `~/Projects/self/zoo.nix/nix/packages/ghostel/default.nix` —
a Zig build with two fixed-output hashes, about 130 lines across two files. It
built, and `just check` passed against it. `code-critic` then pointed out that
nixpkgs ships it, and both derivations were deleted.

The measurement behind that error is worth naming precisely, because the obvious
reading of it is wrong. We had checked `<nixpkgs>`, which on this machine is a
`25.11pre-git` channel snapshot older than either input the flake went on to
pin. Both packages are absent there. They are also absent from the locked
`release-25.11` (`cd648d6`), and present in locked `nixpkgs-unstable`
(`a5cbcfe`) at 0.48.0 — so the conclusion held by luck, not by method.

**A `NIX_PATH` channel is not your locked input, and answers a different
question.** Evaluate against the flake you intend to pin.

## What we built

`flake.nix` carries inputs, `systems`, the nixDir block, and
`flake.overlays.default`. Everything else lives under `nix/`, described in the
addendum. `git show ea96f5e` has the rest.

The one shape worth stating up front: `nix/overlays/` is the only place a flake
input is read. `local.nix` is a plain function of a package set; the other three
take `inputs` before the usual `final: prev`. That keeps every package under
`nix/packages/` usable from any nixpkgs rather than only from this lockfile.

## Facts worth keeping

Established by experiment, and not recoverable from the code.

- **`HERDR_SOCKET_PATH` isolates both ends of an integration run.** The herdr
  CLI binds it and `herdr-api-socket-path` discovers it, so one variable keeps a
  test away from the session owning the user's real panes. `XDG_CONFIG_HOME`
  does **not** isolate it — herdr still reported `~/.config/herdr/herdr.sock`.
  `herdr --session <name>` is the other way in, giving
  `~/.config/herdr/sessions/<name>/herdr.sock`. The socket path has to fit
  `sun_path`, which is why the integration shell keeps it short.
- **Mixing channels for ghostel costs nothing in the closure.**
  `release-25.11` and unstable both ship Emacs 30.2, from different derivations,
  so ghostel's dynamic module compiles against a sibling build of the Emacs that
  loads it. `nix path-info -r` on the wrapper finds exactly one Emacs, the
  release one (`bgfi11n…`), because a melpaBuild output keeps no runtime
  reference to its build-time Emacs. `just check` exercises the load, since
  `require 'ghostel` pulls the module in — so a suite pass is the ABI check.

## Current state

`ea96f5e` is on master, the tree is clean, and the repo still has no remote. The
pre-commit hook passed on its own commit.

Verified: `nix develop --command just check` → 68/68; both dev shells and all
packages build; `herdr status server` inside the integration shell reports
`not running` at `/run/user/1000/herdr-el-dev.sock`, so it cannot reach the live
session; the home-manager module evaluates against stub options with both
supervisor branches forced.

## Next steps

Unchanged from the porcelain session — none were touched.

- Add tabs-to-workspace functionality, with a keybinding to rename them.
- Add dedicated commands to jump to the spaces and agents buffers.
- Investigate playing a sound when a session asks for attention, as herdr does.
- Write a skill mirroring the herdr one but with an Emacs backend, driving
  `emacsclient`.

## Gaps

- **The Darwin branch of the module is unverified.** Same gap the zoo.nix
  version has: no darwin configuration exists to evaluate it against. The
  `launchd.agents` block is written to spec.
- **`overlays.default` exports only `herdr`.** That was deliberate: the Emacs
  wrapper and the check runner exist to develop this repo. The consequence is
  that the flake exports no packaged herdr.el, only the daemon it wraps, and a
  consumer wanting `herdr-el-emacs` must reach into `packages.<system>`.
- **The integration shell has no scripted scenario.** It pairs Emacs and a herdr
  daemon on an isolated socket and stops there. Nothing drives a pane.

## Skills and meta

- **Steering.** `code-critic` found the vendored ghostel duplicated nixpkgs,
  which is what deleted 130 lines. It also disproved a comment claiming `emacs`
  and `emacsPackages` must be overridden together, by overlaying `emacs` alone
  and watching `emacsPackages.emacs` follow. Two findings were not taken: it
  wanted the devshell duplication left alone (agreed, left), and it wanted
  `evil-ghostel` dropped from the wrapper (kept, because it rebinds input paths
  `herdr-term.el` drives).
- **Steering.** `prose-critic` reviewed this handoff and reported as a blocker
  that the locked release channel already ships ghostel. It does not — it had
  evaluated a nixpkgs other than the one in `flake.lock`. The finding was
  rejected on measurement, but the underlying observation was right and produced
  the precision fix above. **A critic's factual claim about a pinned dependency
  needs re-measuring against the lockfile before it is acted on.**
- **Steering.** Review rounds established two durable preferences: pin `nixpkgs`
  to the latest release and reach for `nixpkgs-unstable` only where needed; and
  extend a nested package set through its own `overrideScope` rather than
  inventing a top-level attribute, so it stacks with `emacs-overlay`.
- **Meta.** Spiking external behaviour before designing around it paid twice.
  The `HERDR_SOCKET_PATH` probe found both that `XDG_CONFIG_HOME` does not
  isolate a server and that a long socket path is rejected outright — either
  would have surfaced later as a confusing failure.
- **Meta.** A review boundary needs a commit. Both reviews ran against
  uncommitted work, so the second had no way to show only what changed since the
  first. We rebuilt the boundary on a throwaway branch from an exact copy of the
  reviewed `flake.nix` plus reversed edits, reviewed the range, then deleted it.
  Committing before a review is cheaper than reconstructing after one.

## Addendum: key files

- `flake.nix` — inputs, `systems`, nixDir configuration, `overlays.default`.
- `nix/overlays/default.nix` — the overlay list; add a file and a line here.
- `nix/overlays/emacs-packages.nix` — the `overrideScope` bringing ghostel and
  evil-ghostel in from unstable, with the ABI reasoning in its header.
- `nix/devshells/default.nix` — the hermetic gate; no herdr, no daemon, because
  nothing under `test/` spawns a process and `herdr-api-tests.el` stands up its
  own server.
- `nix/devshells/integration.nix` — socket isolation and the `sun_path` reason.
- `nix/packages/herdr-el-check.nix` — the gate as a runnable package, with its
  tools baked into PATH so the hook holds when committing from magit.
- `nix/modules/home-manager/herdr.nix` — the daemon as a systemd user service or
  a launchd agent.
- `justfile` — unchanged. `just check` is still the gate; the flake now supplies
  what `_load-path` needs.
