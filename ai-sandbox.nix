{ config, lib, pkgs, ... }:

let
  cfg = config.programs.ai-sandbox;

  aiSandboxFiles = pkgs.runCommand "ai-sandbox-files" {} ''
    mkdir -p "$out"
    cp ${./Dockerfile} "$out/Dockerfile"
    cp ${./container-entrypoint.sh} "$out/container-entrypoint.sh"
    chmod 0644 "$out/Dockerfile" "$out/container-entrypoint.sh"
  '';

  aiSandboxScript = pkgs.writeShellScriptBin "ai-sandbox" ''
    export AI_SANDBOX_IMAGE=${lib.escapeShellArg cfg.imageName}
    export AI_SANDBOX_HOME_VOLUME=${lib.escapeShellArg cfg.homeVolumeName}
    export AI_SANDBOX_NIX_VOLUME=${lib.escapeShellArg cfg.nixVolumeName}
    export AI_SANDBOX_BUILD_CONTEXT=${lib.escapeShellArg aiSandboxFiles}
    export PATH=${lib.makeBinPath [
      pkgs.podman
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.findutils
      pkgs.util-linux
      pkgs.bash
    ]}:$PATH

    exec ${./ai-sandbox} "$@"
  '';

  aisScript = pkgs.writeShellScriptBin "ais" ''
    exec ${aiSandboxScript}/bin/ai-sandbox "$@"
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
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      aiSandboxScript
      aisScript
      pkgs.podman
      pkgs.xorg.xhost
    ];
  };
}