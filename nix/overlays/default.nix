# Every overlay in this repository, so flake.nix carries inputs and nothing
# else. `local` is a plain function of a package set; the rest need an input,
# which is why they take one before the usual `final: prev`.
inputs:

{
  emacs-packages = import ./emacs-packages.nix inputs;
  git-hooks = import ./git-hooks.nix inputs;
  herdr = import ./herdr.nix inputs;
  local = import ./local.nix;
}
