{ config, lib, pkgs, ... }:

let
  cfg = config.programs.ai-sandbox;

  aiSandboxFiles = pkgs.runCommand "ai-sandbox-files" {} ''
    mkdir -p "$out"
    cp ${./Dockerfile} "$out/Dockerfile"
    cp ${./container-entrypoint.sh} "$out/container-entrypoint.sh"
    cp ${./ai-sandbox-open-url.sh} "$out/ai-sandbox-open-url.sh"
    cp ${./ai-sandbox-xdg-open.sh} "$out/ai-sandbox-xdg-open.sh"
    chmod 0644 \
      "$out/Dockerfile" \
      "$out/container-entrypoint.sh" \
      "$out/ai-sandbox-open-url.sh" \
      "$out/ai-sandbox-xdg-open.sh"
  '';

  aiSandboxScript = pkgs.writeShellScriptBin "ai-sandbox" ''
    export AI_SANDBOX_IMAGE=${lib.escapeShellArg cfg.imageName}
    export AI_SANDBOX_HOME_STORAGE=${lib.escapeShellArg cfg.homeStorage}
    export AI_SANDBOX_NIX_STORAGE=${lib.escapeShellArg cfg.nixStorage}
    export AI_SANDBOX_BUILD_CONTEXT=${lib.escapeShellArg aiSandboxFiles}
    export AI_SANDBOX_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
    export AI_SANDBOX_NETWORK_MODE=${lib.escapeShellArg cfg.networkMode}
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
        | head -n 1
    }

    container="$(pick_container)"
    if [ -n "$container" ]; then
      exec podman exec "$container" /usr/local/bin/ai-sandbox-open-url "$url"
    fi

    exec code --open-url "$url"
    echo "No running AI sandbox container found for URL callback, and host VS Code failed to handle --open-url." >&2
    exit 1
  '';
in
{
  options.programs.ai-sandbox = {
    enable = lib.mkEnableOption "AI sandbox launcher";

    imageName = lib.mkOption {
      type = lib.types.str;
      default = "ai-sandbox-vscode";
    };

    homeStorage = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.cache/ai-sandbox/home";
      description = "Absolute host path (preferred) or Podman volume name for sandbox HOME storage.";
    };

    nixStorage = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.cache/ai-sandbox/nix";
      description = "Absolute host path (preferred) or Podman volume name for sandbox /nix storage.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/ai-sandbox";
    };

    networkMode = lib.mkOption {
      type = lib.types.enum [ "host" "bridge" ];
      default = "host";
      description = "Container network mode. Use host to support localhost OAuth callbacks generically.";
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

    home.activation.aiSandboxMime = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.xdg-utils}/bin/xdg-mime default ai-sandbox-vscode-url-handler.desktop x-scheme-handler/vscode >/dev/null 2>&1 || true
      ${pkgs.xdg-utils}/bin/xdg-mime default ai-sandbox-vscode-url-handler.desktop x-scheme-handler/vscode-insiders >/dev/null 2>&1 || true
      ${pkgs.xdg-utils}/bin/xdg-settings set default-url-scheme-handler vscode ai-sandbox-vscode-url-handler.desktop >/dev/null 2>&1 || true
      ${pkgs.xdg-utils}/bin/xdg-settings set default-url-scheme-handler vscode-insiders ai-sandbox-vscode-url-handler.desktop >/dev/null 2>&1 || true
    '';
  };
}
