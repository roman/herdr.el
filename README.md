# herdr.el

herdr.el is an Emacs extension that shows you every coding agent running under [herdr](https://github.com/herdrdev/herdr), and
puts their terminals in Emacs buffers.

It does not reimplement herdr. It is a porcelain over herdr's public JSON API; the herdr
server keeps owning the PTYs, the multiplexing, the persistence, and the agent detection,
and Emacs reads the verdict. Anything you run in a herdr pane is tracked, not only agents
that speak a protocol.

## Emacs version

Emacs 29.1 or later. The terminal plane is Unix only — herdr's own terminal attach returns
`Unsupported` on Windows.

## Dependencies

This extension will require:

* [herdr](https://github.com/herdrdev/herdr) — the server, running. Not an Emacs package; `herdr.el` reaches it over a Unix socket.
* [magit-section](https://github.com/magit/magit) 4.0 — draws the panels.
* [ghostel](https://github.com/dakra/ghostel) 0.48 — renders the terminal buffers. It is a dynamic Zig module built on
  libghostty-vt, the same VT engine herdr vendors on the server, so colour, styling, and
  hyperlinks survive the trip with no fidelity loss.

The Reviews panel additionally wants the `herdr-meat-review` script, which ships in the
[herdr-meat-review](https://github.com/roman/herdr-meat-review) project rather than here. Everything else works without it.

Sounds want nothing, until you name a file for one — then they want a player to hand it to.
The bell needs neither.

## Installation

There is no `herdr.el` file to load. The package is a set of libraries, and the one you want
is `herdr-ui`:

```elisp
(require 'herdr-ui)
```

### Nix

The flake exposes an overlay carrying herdr itself, and a home-manager module that
guarantees a server is running:

In your `flake.nix`

```nix
{
  inputs.herdr-el.url = "github:roman/herdr.el";
  # ...
}
```


In your home-manager module
```nix
{
  nixpkgs.overlays = [ inputs.herdr-el.overlays.default ];

  imports = [ inputs.herdr-el.homeManagerModules.herdr ];

  programs.herdr = {
    enable = true;
    settings.keys.prefix = "ctrl+b";
  };
}
```

`programs.herdr.server.enable` is on by default and runs the headless server
as a systemd user service on Linux or a launchd agent on Darwin. herdr
auto-spawns a server on first client use anyway, so this only guarantees an
always-on daemon owning the default socket — which is what an external
client such as herdr.el wants to be able to assume.

### Manual

Clone the repository, put it on your `load-path`, and install magit-section
and ghostel yourself:

```elisp
(add-to-list 'load-path "~/src/herdr.el")
(require 'herdr-ui)
(require 'herdr-review) ; optional; see below
(require 'herdr-sound)  ; optional; see below
```

## Getting Started

One command:

```
M-x herdr-ui
```

That connects to the server, starts tracking the session, and lays out a
column of panels down the left with a terminal filling the rest. From there:

* `RET` on a row opens that pane's terminal.
* `C-c C-b` shows or hides the column, from either side of the layout.
* `M-x herdr-ui-quit` takes the panels off the frame and stops tracking.
  Terminal buffers stay, because a pane you are working in is work in
  progress rather than furniture.

Each panel also opens on its own — `M-x herdr-spaces`, `M-x herdr-agents`,
`M-x herdr-review` — if you would rather arrange the windows yourself.

### Naming a row instead of walking to it

Walking a panel is the right way to browse. Once you know where you are
going, typing the name is quicker, and three commands read one:

| Command              | Reads                                            |
|----------------------|--------------------------------------------------|
| `herdr-spaces-visit` | every workspace, in the panel's grouped order    |
| `herdr-agents-visit` | every agent, the ones wanting attention first    |
| `herdr-review-visit` | every open review, the ones waiting on you first |

Each prompts with the same line the panel draws — status mark, name, and
the notes underneath brought up onto the end of it — so the directory
under a workspace and the title an agent gave itself are both there to be
typed at and to be read back. Candidates keep the panel's order, which is
the order that puts a blocked agent at the top.

Because a row opens with its status mark, nothing you type is ever a
prefix of a candidate, and `basic` — what Emacs completes with until told
otherwise — matches only prefixes. herdr therefore registers its
candidates under the `herdr-pane` completion category and gives that
category `substring` as well. Your own `completion-category-overrides`
still wins, so orderless or fuzzy matching goes on doing what you set it
up to do.

They land exactly where `RET` on the row would, `herdr-panel-visit-access`
and its prefix argument included, and they work with no panel on the frame:
the session starts itself if nothing has started it yet.

```elisp
(keymap-global-set "C-c h s" #'herdr-spaces-visit)
(keymap-global-set "C-c h a" #'herdr-agents-visit)
(keymap-global-set "C-c h r" #'herdr-review-visit)
```

## Example + explanations

```elisp
(require 'herdr-ui)
(require 'herdr-review)                        ;; (1)
(require 'herdr-sound)                         ;; (2)
(herdr-sound-mode)

(setq herdr-sound-request-file "~/sounds/attention.mp3")
(setq herdr-sound-agents '(("droid" . off)))

(setq herdr-ui-panels                          ;; (3)
      '((herdr-spaces-panel . 3)
        (herdr-agents-panel . 2)
        (herdr-review-panel . 1)))

(setq herdr-ui-side-width 36)
(setq herdr-panel-visit-access 'observe)       ;; (4)
(setq herdr-agents-icons                      ;; (5)
      '(("claude" . "✳")
        ("codex" . "◆")))
(setq herdr-api-socket "~/.config/herdr/sessions/work/herdr.sock") ;; (6)
(setq herdr-spaces-git nil)                    ;; (7)
(setq herdr-panel-attention-pulses 3)          ;; (8)
(setq herdr-panel-attention-pulse-interval 0.4)

(keymap-global-set "C-c h" #'herdr-ui)
```

### (1) The Reviews panel is opt in

`herdr-review` is not loaded with the rest of herdr, because it needs a tool
herdr does not: the `herdr-meat-review` script, which starts and ends a review.
The library keeps the shorter name because Emacs Lisp names a library after
the file that holds it; the script says which kind of reviewer it waits on.
Requiring it is what puts the Reviews panel in the column and takes review
rows out of the Agents panel, so that a review appears in exactly one place.

herdr has no concept of a code review and needs none. The review reports
itself over the socket as an agent of kind `review`, so herdr rolls its state
up to the tab and the workspace exactly as it does for a coding agent, and
every herdr client sees a blocked review without being taught anything.

In the panel, `+` starts a review of the workspace at point and `-` ends it.
A workspace holds one review at a time; asking for a second goes to the
first. Point that at your own tool by setting `herdr-review-program`.

### (2) Sounds are opt in, and follow herdr's decisions

`herdr-sound-mode` rings when an agent starts waiting for you, and rings
again when one finishes work you were not watching. herdr splits this the
same way: its server decides that a state changed and forwards a
notification, and each connected client makes the noise. The server plays
nothing itself, so an Emacs that never attaches a herdr terminal hears
nothing until this is on.

Whether a finish is worth announcing is herdr's call, not ours. On the wire
`done` and `idle` are one state told apart by whether herdr holds you to
have watched the work end — `done` is the finish it wants announced, `idle`
the one it has already discounted. A finish is dropped again here when the
pane is on screen in Emacs, which is the one question herdr cannot answer
for you.

The default is the bell, because herdr's own two sounds are mp3 files
compiled into its binary with no copy on disk, and Emacs plays only wav and
au. Name a file in `herdr-sound-request-file` or `herdr-sound-done-file` and
it goes to the first installed player in `herdr-sound-players` — herdr's own
list, which leaves out bare `aplay` because it does not decode mp3 and would
play the bytes as raw noise. `herdr-sound-agents` silences one kind of agent,
as herdr's per-agent table does, and ships `droid` off for the same reason.

### (3) The column is a list of panels

`herdr-ui-panels` is an alist of `(FUNCTION . WEIGHT)`, top to bottom. The
weights are shares counted against each other rather than fractions, so
dropping a panel leaves the rest in proportion. Spaces outweighs agents
because it lists every workspace while agents lists only the panes herdr
found one running in.

An entry whose function is undefined is skipped rather than signalled, which
is how the optional Reviews panel keeps its place in the order without
costing anything when it is not loaded.

### (4) Who holds the keyboard

herdr grants control of a pane to one client at a time, so a terminal opened
from a panel takes the keyboard away from wherever it was — including from
the herdr TUI. `herdr-panel-visit-access` chooses which you get by default:

* `control` — the terminal takes what is typed at it. Usually what opening
  one is for, and the default.
* `observe` — the terminal only shows the pane, and control stays put. Worth
  having when a panel is being read rather than acted on.

A prefix argument to `herdr-panel-visit` asks for the other one.

### (5) Marking the Agents panel

The Agents panel lists every agent herdr has detected, loudest first: it
answers "who wants me", so the order is by attention rather than by position
in the tree. `herdr-agents-icons` gives a kind a glyph in place of its name,
and `herdr-agents-icon-faces` gives it a colour. A kind with neither keeps
its name, which says more than a generic mark would.

The default glyph for Claude is the mark Claude Code puts in its own terminal
title, because Nerd Fonts carries no Claude glyph. Put a private codepoint
there if your font has the real logo.

`herdr-agents-hidden-kinds` leaves a kind out entirely. It exists so that a
kind with a panel of its own is not listed twice — `herdr-review` adds itself
to it — rather than as a general filter.

### (6) Which server

By default the socket is discovered: `HERDR_SOCKET_PATH` first, which herdr
exports into every pane it owns — so an Emacs started from inside herdr
reaches its own server without being told — then `herdr/herdr.sock` under
your XDG configuration directory. Set `herdr-api-socket` to reach a named
session instead.

Only the frame stream uses herdr's command line. Everything structural goes
over the JSON API socket, which herdr documents for third-party tools.
herdr.el never speaks the private binary client protocol.

### (7) Git state costs a subprocess

herdr computes the branch and dirty state it draws on a space but puts
neither on the wire, so herdr.el asks git itself, cached for
`herdr-spaces-git-ttl` seconds. Set `herdr-spaces-git` to nil if you would
rather it did not.

### (8) A row wanting you flashes rather than staying lit

An agent that starts waiting for an answer, or that finishes work nobody
watched, fills its whole row with colour — red for the first, green for the
second — because a mark one character wide in a column of marks is easy to
walk past. The fill flashes `herdr-panel-attention-pulses` times, each phase
lasting `herdr-panel-attention-pulse-interval` seconds, and then goes. What
the agent wants is left to its mark, which keeps the colour for as long as
the status does.

The flash is aimed at the corner of your eye while you work, so it is shown
only for a row this Emacs has a buffer for. A workspace you never opened
here still shows its mark, and the sounds of `herdr-sound-mode` are what
carry a finish you are nowhere near.

Set `herdr-panel-attention-pulses` to 0 to have the panels say all of this
with their marks alone, and `herdr-panel-attention-faces` to choose which
statuses flash and in what colour.

## Keys

Shared by every panel:

| Key                          | Command                                       |
|------------------------------|-----------------------------------------------|
| `RET`                        | `herdr-panel-visit` — open the row's terminal |
| `n` / `p`, `<down>` / `<up>` | move a row                                    |
| `g`                          | `herdr-panel-refresh`                         |
| `q`                          | `quit-window`                                 |
| `C-c C-b`                    | `herdr-ui-toggle-panels`                      |

In a terminal buffer:

| Key                      | Command                                                      |
|--------------------------|--------------------------------------------------------------|
| `C-c C-l`                | `herdr-term-resync` — reconnect for a fresh full frame       |
| `C-c C-w`                | `herdr-term-take-control` — steal the keyboard for this pane |
| `C-c C-k`                | `herdr-term-close`                                           |
| `C-c C-e`                | `herdr-term-scroll-to-bottom`                                |
| `S-<prior>` / `S-<next>` | page the scrollback                                          |

The shifted page keys are what a terminal emulator conventionally uses for
its own scrollback, which leaves the unshifted ones to reach the program
running in the pane.

evil users get the motions they expect. A panel is a list herdr owns and
nothing in it can be edited, so the keys that would silently enter insert
state are refused rather than left to do nothing anyone asked for. In a
terminal, insert state hands `DEL`, `C-a`, `C-e`, `C-k` and the rest to the
program, because evil's own bindings would otherwise take the shell's line
editing away; `C-o` and `C-z` are deliberately left to evil, as the way back
out of a terminal that has the keyboard.

## Living with other window packages

Packages that resize or fade windows behind your back fight a fixed layout.
golden-ratio regrows whichever window you select, so a panel changes width as
you move through it. dimmer greys out every window but the selected one, so
reading the terminal dims the panels that exist to be glanced at.

`herdr-ui-tame-window-packages` is on by default and exempts the herdr
windows from both, only while the layout is on the frame. Both packages
behave as they always did everywhere else.

## Development

The whole gate is one recipe:

```
just check
```

which byte-compiles the package and its tests with warnings as errors, runs `check-declare`
over every `declare-function`, runs checkdoc, and then runs the ERT suites. `just
test-interactive` runs the same suites in a live Emacs when you need to step through a
failure. `nix develop` gives you a shell with an Emacs carrying every dependency, and installs
the same gate as a pre-commit hook.

The suites are hermetic: nothing under `test/` spawns a herdr binary, and the API tests stand
up their own server on a temporary socket. Use the `integration` devshell to drive a real one.

Pull requests are very welcome! Please try to follow these simple rules if applicable:

* Please create a topic branch for every separate change you make.

* Update the README file.

* Make sure `just check` passes.

* Please **do not change** the version number.

#### Open Commit Bit

herdr.el has an open commit bit policy: anyone with an accepted pull request gets added as a
repository collaborator. Please try to follow these simple rules:

* Commit directly onto the master branch only for typos, improvements to the readme and
  documentation.

* Create a feature branch and open a pull-request early for any new features to get
  feedback.

* Make sure you adhere to the general pull request rules above.

## License

```
 herdr.el - An Emacs porcelain for the herdr terminal multiplexer

 Copyright (C) 2026  Roman Gonzalez and collaborators.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
```
