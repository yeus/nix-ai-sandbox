{ config, lib, pkgs, ... }:

let
  cfg = config.programs.ai-sandbox;

  aiSandboxFiles = pkgs.runCommand "ai-sandbox-files" {} ''
    mkdir -p "$out"
    cp ${./Dockerfile} "$out/Dockerfile"
    cp ${./container-entrypoint.sh} "$out/container-entrypoint.sh"
    cp ${./ai-sandbox-open-url.sh} "$out/ai-sandbox-open-url.sh"
    chmod 0644 "$out/Dockerfile" "$out/container-entrypoint.sh" "$out/ai-sandbox-open-url.sh"
  '';

  aiSandboxScript = pkgs.writeShellScriptBin "ai-sandbox" ''
    export AI_SANDBOX_IMAGE=${lib.escapeShellArg cfg.imageName}
    export AI_SANDBOX_HOME_VOLUME=${lib.escapeShellArg cfg.homeVolumeName}
    export AI_SANDBOX_NIX_VOLUME=${lib.escapeShellArg cfg.nixVolumeName}
    export AI_SANDBOX_BUILD_CONTEXT=${lib.escapeShellArg aiSandboxFiles}
    export AI_SANDBOX_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
    export PATH=${lib.makeBinPath [
      pkgs.podman
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.findutils
      pkgs.util-linux
      pkgs.bash
      pkgs.gnused
      pkgs.procps
    ]}:$PATH

    exec ${./ai-sandbox} "$@"
  '';

  aisScript = pkgs.writeShellScriptBin "ais" ''
    exec ${aiSandboxScript}/bin/ai-sandbox "$@"
  '';

  aiSandboxUrlHandler = pkgs.writeShellScriptBin "ai-sandbox-url-handler" ''
    export AI_SANDBOX_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
    export PATH=${lib.makeBinPath [
      pkgs.podman
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.findutils
      pkgs.util-linux
      pkgs.bash
      pkgs.gnused
      pkgs.procps
    ]}:$PATH

    state_dir="''${AI_SANDBOX_STATE_DIR:-$HOME/.local/state/ai-sandbox}"
    mkdir -p "$state_dir"

    url="''${1:-}"
    if [ -z "$url" ]; then
      echo "No URL provided." >&2
      exit 1
    fi

    pick_container() {
      if [ -f "$state_dir/last-container" ]; then
        c="$(cat "$state_dir/last-container" 2>/dev/null || true)"
        if [ -n "$c" ] && podman inspect "$c" >/dev/null 2>&1; then
          if [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = "true" ]; then
            echo "$c"
            return 0
          fi
        fi
      fi

      podman ps \
        --filter label=ai-sandbox=true \
        --format '{{.Names}}' \
        | tail -n 1
    }

    container="$(pick_container)"
    if [ -z "$container" ]; then
      echo "No running AI sandbox container found for URL callback." >&2
      exit 1
    fi

    exec podman exec "$container" /usr/local/bin/ai-sandbox-open-url "$url"
  '';
in
{
  options.programs.ai-sandbox = {
    enable = lib.mkEnableOption "AI sandbox launcher";

    imageName = lib.mkOption {
      type = lib.types.str;
      default = "ai-sandbox-vscode";
    };

    homeVolumeName = lib.mkOption {
      type = lib.types.str;
      default = "ai-sandbox-home";
    };

    nixVolumeName = lib.mkOption {
      type = lib.types.str;
      default = "ai-sandbox-nix";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/ai-sandbox";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      aiSandboxScript
      aisScript
      aiSandboxUrlHandler
      pkgs.podman
      pkgs.xorg.xhost
    ];

    xdg.desktopEntries.ai-sandbox-vscode-url-handler = {
      name = "AI Sandbox VS Code URL Handler";
      exec = "ai-sandbox-url-handler %u";
      terminal = false;
      type = "Application";
      mimeType = [
        "x-scheme-handler/vscode"
        "x-scheme-handler/vscode-insiders"
      ];
      categories = [ "Development" ];
      noDisplay = true;
    };

    xdg.mimeApps.enable = true;
    xdg.mimeApps.defaultApplications = {
      "x-scheme-handler/vscode" = [ "ai-sandbox-vscode-url-handler.desktop" ];
      "x-scheme-handler/vscode-insiders" = [ "ai-sandbox-vscode-url-handler.desktop" ];
    };
  };
}