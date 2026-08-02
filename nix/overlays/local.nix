# What this repository builds for itself.
#
# `final.callPackage`, not `prev.callPackage`: these are ingredients, so they
# must come from the finished package set. A consumer whose own overlay patches
# Emacs would otherwise get a wrapper built against the unpatched one, with two
# Emacsen in the closure and no error to say so.
final: _prev: {
  herdr-el-emacs = final.callPackage ../packages/herdr-el-emacs.nix { };
  herdr-el-check = final.callPackage ../packages/herdr-el-check.nix { };
}
