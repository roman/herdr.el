---
topic: a code review is a herdr agent; herdr.el gained a Reviews panel and herdr-review became its own repo and Claude plugin
date: 2026-08-02
status: Merged — master at 21da86b, 97 tests green, herdr.el and herdr-review pushed
Recurring-friction: git-add-all-sweeps-unrelated-files
---

# Handoff: reviews are first-class in herdr, and the Emacs half landed on master

The session began as a question — could a tuicr review be a first-class
citizen of a herdr session, with a panel of its own beside agents? — and ended
with that shipped across three repositories. herdr itself needed no changes.

The answer turned on one call. herdr's socket API accepts a state report for
**any** agent label, not only the coding agents it detects:

```bash
herdr pane report-agent w1:p4 --source custom:herdr-review --agent review --state blocked
```

herdr then adds the pane to `agent.list`, rolls `blocked` up to the tab and the
workspace, and emits `pane_agent_detected` and `pane_updated` — the stream
`herdr-session.el` already follows. Every herdr client learns about a waiting
review without being taught what a review is.

## Where the code ended up, after two corrections

The split moved twice, both times because Roman said so, and the final rule is
not symmetric — worth stating plainly because the code no longer shows the
reasoning.

It started as `herdr-tuicr/` inside this repo. That became its own repo on the
grounds that "these projects should not be related by source-code
co-location". Then the Emacs half came back here, because herdr.el owns the
Emacs side of herdr and is allowed to know about its neighbours.

So: **herdr-review must be usable without herdr.el; herdr.el may depend on
herdr-review.** The tool repo holds `bin/herdr-review`, the agent skill, and a
bash suite that needs no Emacs. This repo holds `herdr-review.el`, which is not
loaded with the rest of the package — `herdr-ui-panels` names
`herdr-review-panel` and the layout skips any entry whose function is
undefined, so the panel costs nothing until you `(require 'herdr-review)`.

The naming moved for the same reason. Everything was `herdr-tuicr-*` until
Roman pointed out that tuicr is an implementation detail: nothing in Emacs
touches it, since the panel reads agents out of the session tree and shells out
to a script for the rest. It is `herdr-review-*` now, and the kind a review
reports itself as went from `"tuicr"` to `"review"` — that string is the join
between the script, herdr's sidebar, `agent wait`, and the panel, so naming the
work there means swapping the tool reaches none of them.

## Progressive reviews, which the tool now does itself

We reviewed this branch through tuicr four times, and each round had to show
only what arrived since the last. That was hand-run at first: `git update-ref
refs/reviews/<n> HEAD` before opening, then `-r refs/reviews/<n>..HEAD` next
time.

Roman asked whether the skill did that. It did not — the protocol existed only
in a session memory. It is now in the script: `open` with no tuicr arguments
shows the commits since the last marker plus the working tree, leaves a marker
of its own, and `herdr-review marks` lists them.

The previous handoff's closing lesson was that a review boundary needs a
commit. That is now enforced by construction, with one honest limit: markers
track commits, so uncommitted work is shown every round, and the skill says to
commit before asking.

## Facts worth keeping

Established against the live 0.7.5 server, and not recoverable from the code.

- **A reported agent survives a foreground process.** We expected herdr's own
  detection to overwrite a custom report once tuicr occupied the pane. It does
  not: the report stands while the TUI runs.
- **herdr's public ids are base 36.** The pane after `w1:p9` is `w1:pA`. An id
  guard that allowed only digits broke `open` in a workspace on its tenth pane,
  *after* creating the tab — which leaked a tab with nothing in it.
- **`pane focus` moves in a direction; it cannot go to a pane.** `agent focus
  <pane-id>` is how you reach a place, and it works on a custom-reported agent
  like any other.
- **A workspace's directory is not the agent's `$PWD`.** herdr resolves it from
  the first pane of the active tab, so an agent in a worktree reviewing "here"
  gets the parent checkout. Every `herdr-review open` should pass
  `--cwd "$PWD"`.
- **`tuicr review comments` needs `--repo` for a local slug**, or it resolves
  against `.` and reports the session missing.
- **A blocked review shows in herdr's own Agents sidebar**, beside Claude. That
  is unavoidable — it is the same report that makes the rollup work — and herdr
  has no equivalent of `herdr-agents-hidden-kinds` to suppress it.

## Current state

`master` is at `21da86b` and pushed to `github:roman/herdr.el`, which is new
this session. 97 tests pass, up from 68.

The merge was **not** a plain fast-forward: `ea96f5e` and `3892eb3` had landed
on master while the branch was open. No files overlapped, so the seven commits
were rebased onto master and then fast-forwarded, and the gate re-run after the
rebase.

- `github:roman/herdr-review` at `19e09c7` — the script, the skill, the stub
  herdr, 15 bash tests.
- `minerva` at `3c29aa2`, pushed — packages both skills as one `@skills-dir`
  plugin, `herdr:core` and `herdr:review`, and ships the wrapped script.
- `zoo.nix` at `463d907`, **committed but not pushed** — adds
  `reviewPackage = tuicr;` to turn on the review half.

## Next steps

- Push `zoo.nix` and rebuild, which is the only step left to have the plugin
  installed.
- The four porcelain features from two sessions ago are still untouched: tabs
  to workspaces with renaming, jump-to-panel commands, a sound on attention,
  and an Emacs-backend skill driving `emacsclient`.

## Gaps

- **The other seven `.el` files still carry `antrophic@roman-gonzalez.info`.**
  Only `herdr-review.el` was changed to `open-source@`, to keep already-reviewed
  files out of the incremental diffs. A one-commit sweep finishes it.
- **A review of a range still summarises the working tree.** The row's summary
  comes from `git status --porcelain` when the review opens and ignores the
  tuicr arguments, so `-r HEAD~3..HEAD` gets a count of uncommitted files.
- **`herdr-review` has no `shellcheck` in the environment**, so `just lint`
  parses the scripts and skips the linting with a note.

## Skills and meta

- **Skills used.** `elisp-development` for every `.el` file;
  `nixdir-skill-packaging` for the minerva plugin; `skill-creator` as the rubric
  for assessing the agent skill; `writing:handoff` here.
- **Steering.** `code-critic` reviewed the elisp and found two bugs a test would
  have caught, which is what produced `test/herdr-panel-tests.el` and the
  claim-then-verify race fix. It also found four pieces of configurability that
  nothing exercised — a dead `weight` option, a defcustom that had to match a
  string in a shell script — and those were deleted rather than defended.
- **Steering.** `code-critic` assessed the agent skill against Anthropic's
  skill-authoring guidance and found three paths that ended with the agent
  reporting an approved review that never happened: the wrong directory, a
  `--repo` omission, and reading `{}` as "the reviewer finished". All three were
  real. **A skill that lies to an agent is worse than a missing skill, and the
  lie is usually a claim about a neighbouring tool rather than about itself.**
- **Steering.** Roman rejected the name `herdr-tuicr` twice — first for the
  Emacs package, then for the repository — and rejected a required
  `reviewPackage` that would have forced tuicr onto anyone enabling the plugin.
  The pattern in all three: **name and scope things by the work, not by the tool
  that happens to do it today.**
- **Meta.** `git add -A` swept unrelated files into two commits: an empty
  `hello.txt` that was sitting untracked in minerva, and an elisp change that
  landed under a justfile commit message. Both had to be undone afterwards.
  Stage by path when a commit has a subject.
- **Meta.** Replacing the justfile's hand-written file list with `*.el` globs
  immediately broke the suite, which is how we learned the list had been
  carrying a **load order**: one suite `require`s another's fixtures, and `-l`
  on that file afterwards loads it twice, which ERT rejects. The recipes now
  `require` each suite, so the order is irrelevant rather than accidentally
  correct.
- **Meta.** `set -o pipefail` plus a `grep` that legitimately matches nothing
  fails the whole pipeline. It killed the marker lookup before any marker was
  written, and only a test caught it.

## Addendum: key files

- `herdr-review.el` — the Reviews panel, `herdr-review` to show it, and
  `herdr-review-open` / `herdr-review-close`. Not loaded with the package.
- `herdr-ui.el` — `herdr-ui-panels` is the column, `(FUNCTION . WEIGHT)` per
  entry, undefined functions skipped. Replaced `herdr-ui-spaces-height`, now
  obsolete.
- `herdr-agents.el` — `herdr-agents-hidden-kinds` keeps a kind with its own
  panel out of this one.
- `herdr-panel.el` — the `boundp` guards that let a panel run before
  herdr-term is loaded, which was broken before this session.
- `justfile` — `*.el` and `test/*.el`, suites loaded by `require`.
- `~/Projects/oss/herdr-review/bin/herdr-review` — the review lifecycle, the
  one-per-workspace rule, and the `refs/reviews/<n>` markers.
