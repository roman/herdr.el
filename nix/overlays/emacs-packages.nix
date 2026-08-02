# ghostel reached nixpkgs after the release branched, so it comes from the
# unstable channel until the next release carries it.
#
# It goes into the emacsPackages scope rather than the top level, because a
# nested package set does not consult top-level attributes. `overrideScope` is
# that scope's own mechanism, which is also what emacs-overlay uses, so the two
# stack instead of clobbering each other.
#
# The two channels ship the same Emacs version but not the same derivation, so
# ghostel's dynamic module is compiled against a sibling build of the Emacs that
# loads it. Emacs keeps the module ABI stable across a major version, and
# `just check` proves it: `require 'ghostel' loads the module.
inputs:

_final: prev:
let
  unstable = inputs.nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system};
in
{
  emacsPackages = prev.emacsPackages.overrideScope (
    _final: _prev: {
      inherit (unstable.emacsPackages) ghostel evil-ghostel;
    }
  );
}
