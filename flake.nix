{
  description = "herdr.el, an Emacs porcelain for the herdr terminal multiplexer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.11";

    # ghostel landed in nixpkgs after the release branched, and it is the only
    # thing here that reaches past the release channel. multiverse addresses an
    # unstable revision without being one: it declares `inputs = { }` and fetches
    # the revision with `builtins.fetchTree` when the overlay is forced, so a
    # consumer that only wants this repository's source tree never pays for a
    # second nixpkgs. Nothing to `follows` here for the same reason.
    multiverse.url = "github:fzakaria/nixpkgs-multiverse";

    systems.url = "github:nix-systems/default";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    nixDir.url = "github:roman/nixDir/v3";
    nixDir.inputs.nixpkgs.follows = "nixpkgs";

    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # herdr pins its own nixpkgs and rust-overlay for the Rust plus vendored
    # libghostty-vt (Zig) build. Do not `follows` nixpkgs here: this flake's
    # channel may lack the toolchain that build expects, and letting herdr keep
    # its locked inputs matches how upstream tests the package.
    herdr.url = "github:herdrdev/herdr";
  };

  outputs =
    inputs:
    let
      overlays = import ./nix/overlays inputs;
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [ inputs.nixDir.flakeModule ];

      # Only herdr. The Emacs wrapper and the check runner exist to develop
      # this repository, and nothing outside it should find them in `pkgs`.
      flake.overlays.default = overlays.herdr;

      nixDir = {
        enable = true;
        root = ./.;

        # nixDir's own generated overlay resolves through
        # `inputs.self.packages`, so installing it would make each package part
        # of the fixpoint that defines it. The overlays in nix/overlays are
        # written by hand instead, on `final.callPackage`, so a consumer's
        # overrides reach the dependencies.
        generateFlakeOverlay = false;

        installOverlays = builtins.attrValues overlays;

        # Turn a directory nixDir skipped, for depth or a blocking sibling
        # file, into an error rather than an output that quietly never appears.
        strictDiscovery = true;
      };
    };
}
