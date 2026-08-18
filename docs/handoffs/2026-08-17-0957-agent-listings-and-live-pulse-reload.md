---
topic: Agent visits gained Codex rename labels and aligned columns, Spaces kept workspace context only, master was pushed at 35179ff, and reloading a mixed Emacs session restored the live attention pulse
date: 2026-08-17
status: herdr.el master at 35179ff and pushed; 237 tests plus byte compilation, check-declare and checkdoc green; feature branch deleted; running Emacs carries hand-loaded checkout libraries; this handoff is uncommitted
Recurring-friction: emacs-partial-library-reload
---

# Handoff: aligned agent listings landed and the live pulse was restored

Roman wanted the visit prompts to identify the work behind each agent instead
of repeating the project name. We taught the session model to read Codex names
set by `/rename` from `~/.codex/session_index.jsonl`, while Claude and other
agents kept using their terminal titles. Agent rows suppressed a title that
only repeated the workspace name, and terminal buffers put the resolved title
before the pane ID.

The visit prompts built structured completion fields and formatted them as a
table. Agent titles received a configurable maximum width of 92 columns through
`herdr-panel-visit-title-width`; longer titles were truncated with an ellipsis
and shorter ones were padded so later columns lined up. Formatting used display
width, so wide characters did not shift the table. Rows that became identical
after truncation still selected their own panes.

Spaces stayed on the workspace side of the boundary. The panel and
`herdr-spaces-visit` showed the workspace, path, window count and Git context,
without an agent kind or session title. The visit command also retained the
newer completion behavior already on the remote branch, including grouped
workspace order, omission of workspaces with no pane and the public
`herdr-panel-access` helper.

## Integration and verification

The first commit, `22c0732`, was based on an older feature branch. The remote
branch had gained the completion-visit and input-diversion work, so we rebased
the listing change onto it and kept both test suites. That produced `161a9cb`.

`origin/master` then advanced by 17 commits, including the panel attention
work. We fast-forwarded local master, replayed the listing commit and resolved
the two overlaps by keeping `herdr-session-status` for normalized status while
using `herdr-session-agent-title` for the fingerprint, and by retaining both
the attention-fill and Spaces-boundary tests. The resulting commit was
`35179ff Improve agent and workspace listings`.

`just check` passed on the integrated tree: 237 ERT tests, warning-as-error byte
compilation, check-declare and checkdoc. We pushed `35179ff` to `master`, then
deleted `divert-input-past-the-bridge` locally and remotely. The code worktree
was clean before this handoff, and local master matched `origin/master`.

## Why the pulse did not fire

The source was correct, but the running Emacs held definitions from two
generations. `herdr-panel--note-attention` and the pulse engine were current,
while the loaded `herdr-agents--entry` still returned the older row shape
without `:id`. Pulse state was recorded under pane IDs, but the renderer had no
ID with which to find it, so the sound hook ran and the row never received an
attention face.

We confirmed the mismatch in the live session: a forced pulse stored five
phases for `w14:p1`, yet the Agents buffer had no
`herdr-panel-attention-done` text property. We reloaded `herdr-session.el`,
`herdr-panel.el`, `herdr-agents.el`, `herdr-spaces.el`, `herdr-review.el` and
`herdr-sound.el` from the checkout as one set. The same reversible check then
returned `:id "w14:p1"` and found `herdr-panel-attention-done` across the full
row.

The live hook order is now pulse detection, terminal renaming, panel redraw and
sound. `herdr-sound-mode` is on, `herdr-panel-attention-pulses` is 3, and both
handlers are present on `herdr-session-change-hook`. The next real transition
to `blocked` or `done` should therefore flash and sound together.

## Current state

The checkout and remote are complete at `35179ff`. No source change was needed
for the pulse diagnosis.

The running Emacs is consistent now only because the related checkout files
were hand-loaded. Its installed Nix package has not been rebuilt from
`35179ff`, so a daemon restart before installation can return to the older
package contents.

## Next steps

- Run `just install` through the configuration that owns the herdr.el package.
- Restart the Emacs daemon and verify one natural `working` to `blocked` or
  `done` transition produces both the row pulse and sound.

## Skills and meta

- **Skills used.** `elisp-development` guided the conflict resolutions and the
  byte-compile/checkdoc gate; `writing:handoff` and
  `socrates:spec-format` shaped this handoff.
- **Meta.** Reloading only one side of a cross-library contract produced a
  failure that the clean source tree and batch suite could not reproduce. When
  a row schema changes, reload the session model, panel engine and every row
  producer together, or restart Emacs from one installed build.
