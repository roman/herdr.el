---
topic: The panel attention fill became a three-flash pulse shown only for rows this Emacs has open, the status marks were saturated, sounds and the other-window cycle were narrowed the same way, and the rapture config moved the visit keys under SPC b h — ten commits, both repos pushed to master
date: 2026-08-15
status: herdr.el master at 2fd6bea and zoo.nix master at 43cb1d2, both pushed; 221 herdr.el tests and 16 rapture plugin tests green; one human review closed LGTM; `just install` has not been run, so the running Emacs still carries hand-loaded copies
Recurring-friction: emacs-reload-font-1px
---

# Handoff: the attention signals now aim at the reader who can see them

Roman had been living with the panels long enough to name what was wrong with
them. The row fill that says an agent wants you arrived with the status and
stayed until the status went, so a column with three waiting agents in it was a
column with a coloured background — the fill had stopped carrying information.
He wanted it to flash three times and settle back to its mark, and he wanted no
signal at all for a workspace this Emacs has no buffer for. Everything else in
the session came out of pulling that same thread: if a signal is for the person
sitting in front of the layout, then the sound, the mark colours and the window
cycle all owe the same answer.

## What changed in herdr.el

**The fill became a pulse.** A row whose status changes into one named in
`herdr-panel-attention-faces` now flashes `herdr-panel-attention-pulses` times
at `herdr-panel-attention-pulse-interval` seconds a phase, then settles to its
mark. The tracker is keyed by what a row stands for, which each panel passes as
the new `:id` of its entry — a pane for agents and reviews, a workspace or a
space for the spaces panel — so the row that changed is the row that flashes and
the rest of the column holds still. It rides `herdr-session-change-hook` at
depth -50, ahead of the redraw already on that hook, so a pulse that begins is
lit by the redraw that follows rather than one tree later. A first sighting is
not a change, or every agent already waiting would flash the moment a panel
opened.

**The fill is withheld from a row nobody here has open.** `:emphasis` is already
`closed` when no buffer mirrors the row, which is what greys its name, so the
fill now asks the question the dimming already asked. A group heading is as open
as its openest member. The mark keeps its colour either way.

**The four status marks left the Catppuccin pastels behind on dark
backgrounds.** Three of the five statuses draw the same glyph and colour is the
whole of what separates them; against black the pastels read as three shades of
pale. Each mark kept Mocha's hue and took as much of it as the terminal gives.
Text fields stayed pastel, which is what leaves the marks the loudest thing in
the column.

**`herdr-sound-panes` gates both sounds on the pane being open here**, default
`open`, `any` for herdr's own reach. It is a separate question from
`herdr-sound-finish`, which asks whether you are *looking* at the pane as the
work ends — open and not on screen is precisely the state a finish is worth
announcing in, so both guards must allow a sound. Reading the pane's buffers
once answers both, which is what `herdr-sound--buffers` now does for
`--open-p` and `--watched-p`.

**The panel column left the `other-window` cycle**, via `no-other-window` in
`herdr-ui--display` and the option `herdr-ui-panel-other-window`. Roman asked
for this to force the habit onto his leader key.

## What changed in the rapture config

The visit commands moved from `SPC v s/a/r` to `SPC b h s/a/r` — reaching a pane
that exists is reaching a buffer, and three commands do not earn a leader key of
their own. `SPC v` now answers nothing, and `C-x b` is unbound so that `SPC b b`
is the only reach for switching buffers.

Two prompt behaviours went in as advice on `herdr-panel-read-pane`, which is
where all three panels turn rows into a pane, so one function covers them:
a single row opens without a prompt, and rows this Emacs has no buffer for sort
below the ones it has. Within each half herdr's loudest-first order stands.

## The font incident

`just reload-emacs` left the default face at height 8 — one pixel, unreadable.
The config already guards against this (`ui/config.org` skips `zoo/set-face-font`
on reload because `set-frame-font` in a non-graphical context corrupts the frame
font), and **the guard held**: `rapture/config-loaded` was `t` and the function
never ran. Something else in the reload path re-resolved the default face while
the graphical frame was not selected. I restored it by calling
`zoo/set-face-font` inside the graphical frame and confirmed no other face was
left at a corrupted absolute height. Nothing was changed on disk, so the next
reload can do it again. `SPC a f f` is the manual undo.

## Facts worth keeping

- **`custom-declare-face` leaves an existing face alone**, so reloading a file
  never changes a colour in a running Emacs. `(put 'face 'face-defface-spec nil)`
  before the load is what makes the new `defface` apply. This cost me one
  confused round trip where the reload reported success and the colours did not
  move.
- **A reload only adds.** Keys and which-key labels set by the previous
  generation survive it, so `SPC v` and its "visit" label were still answering
  after the config that binds them was gone. A fresh Emacs never has them; I
  unbound both by hand in the session.
- **ERT batch runs tests in alphabetical order, not definition order.** The
  rapture herdr suite depends on this:
  `rapture-herdr-sound-turns-on-with-the-panels` asserts the sounds are off
  until something loads `herdr-panel`, so any test that loads it must sort after
  that name. `rapture-herdr-wires-the-single-row-shortcut` does; the ordering
  tests stub `herdr-panel-pane-open-p` instead of loading anything.
- **`other-window` honours `no-other-window`; `next-window` does not.** My first
  test asserted the wrong function and failed on a window it was right to
  return.
- **The index is how to build semantic commits without touching the working
  tree.** `git checkout -- .` was refused by the permission classifier, so each
  commit was assembled with `git hash-object -w` plus
  `git update-index --cacheinfo`, leaving the working tree at the final state
  throughout and verifying at the end that `git diff master...HEAD` matched the
  original uncommitted diff exactly.
- **herdr.el's pre-commit hook runs `just check` against the staged tree**, so
  each of its commits is independently green. zoo.nix's hook only runs `nixfmt`,
  which skips `.org` and `.el` entirely — I verified those intermediate commits
  by building the plugin at each one in a throwaway worktree (11 tests, then 14,
  then 16).

## Current state

herdr.el `master` at `2fd6bea`, pushed. Five commits from this session:
`a0122b3` marks, `1f9d093` pulse, `7a9a795` open-rows-only, `e28abb4` sound
gate, `2fd6bea` window cycle. `just check` green at 221 tests.

zoo.nix `master` at `43cb1d2`, pushed. Five commits: `0f36cda` keys,
`cf53d28` single row, `dd16417` ordering, `ce80fb1` `C-x b`, `43cb1d2` the
`herdr-el` input bump. The bump moved the pin from `4a51267` (Aug 4) to
`2fd6bea`, made herdr.el's new `multiverse` input follow this flake's — two
revisions of it means two builds of ghostel's dynamic module in one Emacs — and
dropped the `nixpkgs-unstable` override that herdr.el no longer has an input
for. `just build` green in 2 minutes; the built store path carries
`herdr-panel-attention-pulses`, `herdr-sound-panes` and
`herdr-ui-panel-other-window`.

**Not installed.** The running Emacs holds hand-loaded copies of the changed
files, a hand-restored font, and hand-unbound `SPC v` keys.

## Next steps

- `just install`, then restart the Emacs daemon. That replaces every hand-loaded
  copy with the store build.
- Delete the merged branches if wanted: `attention-signals` and
  `multiverse-ghostel` in herdr.el, `multiverse-pins` in zoo.nix.

## Gaps

- **The font corruption has no identified cause.** The one guard that exists was
  not the thing that failed, and the fix so far is a manual call. Hardening
  `emacs-reload` to re-apply the font inside the graphical frame it already
  selects is the obvious move and was not made.
- **The sound gate is per-pane, not per-workspace.** With `w7:p1` open and
  `w7:p6` not, an agent in `p6` is silent. That matches the agents row, which is
  dimmed for `p6`, and not the spaces row, which counts a workspace open if any
  pane of it is. Roman was told and did not object; it is worth revisiting if a
  silent finish surprises him.
- **Each pulse phase redraws every panel** — six redraws over about two seconds
  per event, because the fill is merged into panel text rather than laid over
  it. Cheap in a session with three workspaces, unmeasured beyond that.
- **No `code-critic` pass was run.** The session forbids launching agents
  unprompted, so the pre-review pass that `code-refinement.md` asks for did not
  happen; the human review took its place.
- **zoo.nix's `init-claude-skills` branch is still unmerged**, unrelated to this
  work and noticed while checking what "the multiverse changes" meant.

## Skills and meta

- **Skills used.** `elisp-development` for file conventions and the
  compile/checkdoc gate; `herdr:meat-review` to open the review, read the
  comment back and confirm it closed; `writing:handoff` here.
- **Steering.** Roman: "Do not add comments about the absence of deleted
  configuration/code, that's git's job." Three comments and one test name were
  describing what the config used to do. Rewritten to state the current rule.
  The instruction is already in `code-style.md` as "no old-implementation
  breadcrumbs"; I broke it while writing tests that assert an absence, where the
  pull toward narrating the removal is strongest.
- **Steering.** Roman asked for semantic commits twice, in two repos. Both times
  the changes were interleaved across shared files and had to be split by hand.
  Committing per concern as the work happens would have cost nothing; splitting
  afterwards cost two rounds of reconstructing intermediate file states.
- **Steering.** Before pushing, both branches carried Roman's own unpushed
  commits — the multiverse work. I asked rather than assuming, and he chose to
  push everything. Worth keeping: "push to master" from a feature branch is
  ambiguous whenever the branch is not just your own work.
- **Meta.** `checkdoc` rejects third-person verbs anywhere in a docstring, not
  only in the first line ("lets" → "let"), and flags an embedded keycode like
  `C-c C-b`. Both cost a round trip. `\\[command]` is the fix for the second.
- **Meta.** Evaluating changes in the live Emacs through `emacsclient -e` proved
  more useful than any test for the display-level work — it is how the stale
  `SPC v` bindings, the face-spec no-op and the font corruption were all found.
  None of the three would have shown up in batch.
