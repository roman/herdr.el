# The shell for driving a real herdr server from a real Emacs.
#
# herdr.el is a porcelain over a running daemon, so the parts that matter most
# (frame streaming, taking control of a pane, the JSON API) cannot be covered by
# ERT. This shell pairs the two halves and points them at a throwaway session.
pkgs:

let
  socketName = "herdr-el-dev.sock";
in
pkgs.mkShell {
  packages = [
    pkgs.herdr-el-emacs
    pkgs.herdr
    pkgs.just
    pkgs.git
  ];

  shellHook = ''
    # Both the herdr CLI and herdr.el read this variable, so one setting keeps
    # a test run away from the session that owns your real panes.
    #
    # It lives under XDG_RUNTIME_DIR because a socket path must fit in 108
    # bytes, and a path inside the checkout can be longer than that.
    export HERDR_SOCKET_PATH="''${XDG_RUNTIME_DIR:-/tmp}/${socketName}"

    echo "herdr.el drives $HERDR_SOCKET_PATH here, not your own session."
  '';
}
