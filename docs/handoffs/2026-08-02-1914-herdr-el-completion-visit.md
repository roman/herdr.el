---
topic: three completion commands let a herdr.el panel row be named instead of walked to; herdr.el master at efbc58b
date: 2026-08-02
status: Merged — herdr.el master at efbc58b, pushed, 145 tests green
---

# Handoff: a panel row can now be typed at instead of stepped through

The previous session left "add dedicated commands to jump to the spaces and
agents buffers" queued. The operator refined it before any of it was written:
they did not want a command that lands in the panel buffer, they wanted the
row itself read through completion, so that arriving somewhere already known
costs one prompt rather than a walk. The panels and their `RET` stay exactly
as they were.

That produced one commit and three commands — `herdr-spaces-visit`,
`herdr-agents-visit`, `herdr-review-visit` — one per panel, chosen over a
single merged prompt because each panel's list is already sorted the way that
panel wants to be read, and merging three of them throws that away.

## A candidate is the row the panel drew

Each panel already builds a plist describing a row and hands it to
`herdr-panel-insert-entry`. That plist moved into a `--entry` function per
panel, so the inserter and the new reader draw from one description rather
than two.

The one-line form a prompt needs was at first a second renderer walking the
same plist. `code-critic` called it what it was: 28 lines shadowing 38, with
nothing asserting the two agreed, and a `:badge` added later would silently
appear in the column and not in the minibuffer. `herdr-panel-entry-line` now
draws through `herdr-panel-insert-entry` into a temp buffer and folds the
result onto one line. I checked the text and the faces matched the hand-written
version before deleting it; they did, on every spec the tests cover.

Folding needs one detail that is not obvious. `replace-match` does not carry
the text properties of what it replaced, so collapsing each newline to two
spaces punched a two-column hole in the background fill of the current row.
Propertizing the replacement from `text-properties-at` on the newline closes
it, because the fill was applied across the newlines in the first place.

## The status mark defeats prefix matching

This was the finding worth the whole review pass. A row opens with its status
mark, which is what a reader scans a column for and so has to survive into the
prompt. It also means nothing the reader types is ever a prefix of a
candidate, and `basic` — what Emacs completes with until told otherwise —
matches only prefixes. Under a stock `completing-read`, `icomplete` or
`fido-mode`, all three commands would have completed nothing at all.

`completion-category-defaults` is where a library declares how its own
category should be matched, so the rows register under `herdr-pane` and that
category is given `substring` as well.

I expected this to displace the operator's setup, because their
`completion-styles` is `(orderless)` with no category overrides. It does not.
Verified in their daemon: the category's styles are **prepended** to the
global ones, so `herdr-pane` resolves to `(basic substring orderless)`, and
orderless still runs as a fallback for the queries the first two cannot
answer. `herdr master` and `self olym` both matched against real rows.

## Reading rows does not start a session

`herdr-panel-ensure-session` first called `herdr-session-start`, which opens
an event subscription and a repeating poll timer. Nothing stops those but
`herdr-ui-quit` or a panel buffer's `kill-buffer-hook`, and these commands
work with no panel on the frame — so running one on a bare frame leaked both
for the rest of the session. It takes a snapshot instead. Nothing here is
going to be redrawn.

## Facts worth keeping

Established by experiment, and not recoverable from the code that resulted.

- **A category's styles are prepended to `completion-styles`, not substituted
  for them.** `completion--styles` appends the global list after the
  category's, so a library declaring `(styles basic substring)` for its own
  category does not take orderless or fuzzy matching away from a user who set
  it globally. Verified in a live Emacs 30.2 against real candidates.
- **`json-serialize` turns a plist value of `nil` into `{}`, not `null`.** A
  test fixture with `:cwd nil` therefore handed a hash table to
  `abbreviate-file-name` through the snapshot round trip. Omit the key
  instead; nil is the one value that does not survive.
- **`defvar-keymap` expands to a plain `defvar`,** so reloading a file leaves
  every keymap it defines standing. That is what made loading the working tree
  over the nix-store copy in the running daemon safe: no keymap, defcustom or
  user setting was reset.
- **`completion-all-completions` returns an improper list.** Its last cdr is
  the base position as an integer, so `butlast` signals `wrong-type-argument
  listp`. Walk the tail with `consp`.
- **`completing-read` returns the empty string on empty input whatever
  `REQUIRE-MATCH` says.** A reader that maps the answer back to an object has
  to refuse that case itself, or it carries nil forward as if it were a
  choice.
- **tuicr persists no session for a review closed without comments.** The
  newest session file on disk after this session's review belonged to a
  different repository entirely. An empty listing is therefore not evidence
  that a review was silent — it is not evidence of anything.

## Current state

`herdr.el` master is at `efbc58b` and pushed; 145 tests, `nix develop --command
just check` green. The change went through one herdr review round and came
back with no notes.

`test/herdr-spaces-tests.el` is new — `herdr-spaces.el` had no suite before
this session.

The operator's Emacs daemon currently has the working tree loaded over the
nix-store copy, so it is running this change ahead of their flake input. A
restart or a rebuild drops it back to the installed version.

## Next steps

- Bind the three commands in the nix-managed init; the README suggests
  `C-c h s`, `C-c h a`, `C-c h r`.
- Give `herdr-ui--read-pane` and `herdr-ui--read-tab` the same treatment. They
  still prompt with raw identifiers like `w1:p1`, and are now the only readers
  that do.
- Add tabs-to-workspace functionality, with a keybinding to rename them.
- Write a skill mirroring the herdr one but with an Emacs backend, driving
  `emacsclient`.
- Exempt `blocked` and `done` from the dim on an unopened panel entry.
- `herdr-panel-unopened` and `herdr-panel-detail` resolve to one grey under
  two names.
- Add the `just reload` recipe that unbinds the `defvar` family, offered and
  declined three sessions ago.

## Gaps

- **Two workspaces read alike in the live session.** `w13` and `w14` share a
  label and a directory and neither is a worktree, so only the status mark
  separates them; when both settle to one status the lines are identical.
  `herdr-panel--distinct` appends the pane id and keeps them selectable, but
  the panel has drawn those two rows the same way all along. Renaming or
  closing one is the real fix.
- **A space is not offered beside its members.** A group heading leads to its
  first member, so listing both would put that member in the prompt twice.
  That is deliberate, and it means a space of several cannot be reached as a
  space from the prompt the way it can from the panel.
- **The review approval was verbal.** No tuicr session was written for the
  round, so the operator's "no notes" is the record; nothing was read back
  from the tool.

## Skills and meta

- **Skills used.** `elisp-development` for every `.el` file, whose checkdoc
  gate caught an imperative-mood fault. `herdr:review` for the one review
  round. `writing:handoff` here.
- **Steering.** `code-critic` found two defects that reasoning had missed: the
  parallel renderer, and the prefix-matching failure that would have made all
  three commands useless outside orderless. It also proposed replacing the
  empty-input guard with a `DEF` argument, which was declined — opening a
  terminal is too much to do on a stray `RET` — and an `affixation-function`
  in place of the category styles, declined because it would have made the
  directory under a workspace unmatchable. **Record the declines: both were
  reasonable readings that lost to a constraint the critic could not see.**
- **Meta.** My model of `completion-category-defaults` said it would displace
  the operator's orderless, and I nearly reshaped the design around that. One
  `completion--styles` call in their live daemon showed the opposite.
  **Check a precedence rule against the running system before designing
  around it.**
- **Meta.** Loading the working tree into the daemon before the review, rather
  than after landing, is what turned "the completion styles should be fine"
  into six real queries against three real workspaces. The verification cost
  two commands.

## Addendum: key files

- `herdr-panel.el` — `herdr-panel-entry-line` folds an inserted entry;
  `herdr-panel-read-pane`, `herdr-panel--table` and `herdr-panel--distinct`
  are the prompt; `herdr-panel-access` is the shared prefix-argument rule,
  public now that three files outside this one ask it.
- `herdr-spaces.el`, `herdr-agents.el`, `herdr-review.el` — each has a
  `--entry` building the row, a `--read` offering them, and a `-visit`
  command.
- `test/herdr-panel-tests.el` — `herdr-panel-tests-offline` and
  `herdr-panel-tests-choosing` are the fixtures the other three suites use.
  `--table:completes-a-name-past-the-status-mark` asserts both the fix and the
  state it guards against.
