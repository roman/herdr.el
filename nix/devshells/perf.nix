# The shell for the performance harness under perf/.
#
# Every program the harness runs comes from here, so two machines that enter
# this shell measure the same herdr and tools. The scripts start through
# `env bash` and find these first on PATH.
#
# No HERDR_SOCKET_PATH here, unlike the integration shell: `perf/fixture.sh`
# starts its own server under the fixture directory and writes the socket path
# to its env.sh.
pkgs:

pkgs.mkShell {
  packages = [
    pkgs.herdr
    # stdenv already carries both. They are listed because the scripts
    # depend on them by name: bash through `env bash`, and GNU coreutils so
    # that macOS runs the same `seq`, `mktemp` and `sleep` as Linux.
    pkgs.bash
    pkgs.coreutils
    pkgs.git
    pkgs.perl
    pkgs.python3
  ];
}
