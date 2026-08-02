# herdr.el talks to a running herdr server. This module guarantees one exists.
{
  pkgs,
  config,
  lib,
  ...
}:

let
  cfg = config.programs.herdr;
  herdrBin = lib.getExe' cfg.package "herdr";
  settingsFormat = pkgs.formats.toml { };
in
{
  options.programs.herdr = {
    enable = lib.mkEnableOption "herdr, the terminal agent multiplexer, and its headless server daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        pkgs.herdr or (throw ''
          programs.herdr.package has no default here: nixpkgs carries no herdr.
          Add herdr.el's `overlays.default` to `nixpkgs.overlays`, or set
          `programs.herdr.package` to a herdr derivation.
        '');
      defaultText = lib.literalExpression "pkgs.herdr";
      description = "The herdr package to install and run as the server daemon.";
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          theme.name = "catppuccin";
          keys.prefix = "ctrl+b";
          ui.mouse_capture = true;
          terminal.shell_mode = "login";
        }
      '';
      description = ''
        Declarative contents of herdr's `config.toml`, rendered to
        `$XDG_CONFIG_HOME/herdr/config.toml`. Any key from the herdr config
        reference is accepted; herdr validates on load and falls back on unknown
        or invalid keys (`herdr config check` reports them). When left empty no
        file is written and herdr uses its built-in defaults.
      '';
    };

    server.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the herdr headless server as a per-user daemon: a systemd user
        service on Linux, a launchd agent on Darwin.

        herdr already auto-spawns a server on first client use, so this only
        guarantees an always-on daemon that owns the default session socket
        (`~/.config/herdr/herdr.sock`). An external client such as herdr.el can
        then rely on the server being up.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      { home.packages = [ cfg.package ]; }

      # Config changes are deliberately not wired as a service restart trigger:
      # the herdr server owns the running agent panes, and a plain restart kills
      # them (there is no FD handoff). Apply changes to a live server with
      # `herdr server reload-config`; the daemon also picks them up on its next
      # start.
      (lib.mkIf (cfg.settings != { }) {
        xdg.configFile."herdr/config.toml".source =
          settingsFormat.generate "herdr-config.toml" cfg.settings;
      })

      # `herdr server` runs the headless server in the foreground, so both
      # supervisors treat it as a simple long-lived process and relaunch it only
      # when it crashes. No PATH override: herdr spawns the user's login shell
      # for panes, which rebuilds the environment from the profile.
      (lib.mkIf (cfg.server.enable && pkgs.stdenv.hostPlatform.isLinux) {
        systemd.user.services.herdr = {
          Unit = {
            Description = "herdr headless server (terminal agent multiplexer)";
            Documentation = [ "https://herdr.dev" ];
            After = [ "default.target" ];
          };

          Service = {
            Type = "simple";
            ExecStart = "${herdrBin} server";
            ExecStop = "${herdrBin} server stop";
            Restart = "on-failure";
            RestartSec = 2;
          };

          Install.WantedBy = [ "default.target" ];
        };
      })

      (lib.mkIf (cfg.server.enable && pkgs.stdenv.hostPlatform.isDarwin) {
        launchd.agents.herdr = {
          enable = true;
          config = {
            ProgramArguments = [
              herdrBin
              "server"
            ];
            RunAtLoad = true;
            # Relaunch only after a crash, matching the Linux `on-failure`.
            # A clean `herdr server stop` exits 0 and stays down.
            KeepAlive.SuccessfulExit = false;
            ProcessType = "Background";
          };
        };
      })
    ]
  );
}
