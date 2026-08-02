# herdr is not in nixpkgs and builds from its own pinned toolchain, so this
# hands over a finished derivation rather than a recipe.
#
# Overlays reach pkgsCross and pkgsi686Linux too, and herdr publishes for
# neither, so the miss is named instead of left as "attribute missing".
inputs:

_final: prev:
let
  system = prev.stdenv.hostPlatform.system;
in
{
  herdr =
    inputs.herdr.packages.${system}.default
      or (throw "the herdr flake publishes no package for ${system}");
}
