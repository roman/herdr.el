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
#
# `tip` is the newest revision multiverse has indexed, so this tracks unstable
# the same way the channel input did and moves on `nix flake update multiverse`.
# A version pin is not available here: multiverse indexes top-level attributes,
# and these two live in the emacsPackages scope.
inputs:

_final: prev:
let
  unstable =
    (inputs.multiverse.lib.mkMultiverse {
      system = prev.stdenv.hostPlatform.system;
    }).tip;
in
{
  emacsPackages = prev.emacsPackages.overrideScope (
    _final: _prev: {
      inherit (unstable.emacsPackages) ghostel evil-ghostel;
    }
  );
}
