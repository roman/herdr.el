# An Emacs carrying every library herdr.el requires, and nothing else.
#
# `just check` runs `emacs -Q --batch`, which still honours the EMACSLOADPATH
# this wrapper exports, so the justfile's `_load-path` recipe locates ghostel
# and magit-section without reading a user init file.
#
# evil-ghostel is here although nothing requires it: it rebinds input paths
# herdr-term.el drives, so an Emacs without it answers keys differently from
# the one a user runs.
{ emacsPackages }:

emacsPackages.withPackages (epkgs: [
  epkgs.magit-section
  epkgs.ghostel
  epkgs.evil-ghostel
])
