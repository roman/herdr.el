# The shell `just check` runs in: byte-compile, check-declare, checkdoc, ERT.
#
# No herdr binary and no daemon. Nothing under test/ spawns a process, and
# herdr-api-tests.el stands up its own server on a temporary socket, so the
# suite stays hermetic. Use the `integration` shell to drive a real server.
pkgs:

pkgs.mkShell {
  packages = [
    pkgs.herdr-el-emacs
    pkgs.just
    pkgs.git
  ];

  # Installs a pre-commit hook that runs the same gate.
  inherit (pkgs.herdr-el-git-hooks) shellHook;
}
