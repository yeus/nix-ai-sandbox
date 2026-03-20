# AI sandbox for Podman + real VS Code + project flakes

This is the flat-folder version.

Files in this folder:

- `Dockerfile`
- `container-entrypoint.sh`
- `ai-sandbox`
- `ai-sandbox.nix`
- `README.md`

## What it does

- builds one global Ubuntu image with real Microsoft VS Code and Nix
- uses bind-mounted host directories for `/nix` and sandbox home (defaults: `~/.cache/ai-sandbox/nix` and `~/.cache/ai-sandbox/home`)
- mounts the current project at `/workspace`
- if the project is a Git submodule, mounts the top superproject at `/workspace` and opens the submodule path inside it (preserves nested submodule `.git` path resolution)
- if a flake is available, launches via `nix develop`
- if no flake is available, launches plain VS Code / plain shell
- supports multiple concurrent containers per workspace (auto instance names, optional `--instance`)

## Commands

Build/update the base image:

```bash
ai-sandbox build-base
```

Rebuild the base image from scratch (remove old image tag first, keep storage dirs):

```bash
ai-sandbox rebuild
```

Reset sandbox storage (clear `~/.cache/ai-sandbox/nix` and `~/.cache/ai-sandbox/home` by default):

```bash
ai-sandbox reset-storage
```

Warm the current project flake into the shared `/nix` storage directory:

```bash
ai-sandbox warm .
```

Start VS Code for the current directory:

```bash
ai-sandbox start .
```

By default, `start` now streams startup logs (including flake/Nix setup) and auto-detaches once VS Code launch begins.

Start and continue following logs even after VS Code launch:

```bash
ai-sandbox start . --logs
```

Start with a stable instance suffix (useful for multiple VS Code windows/workspaces side by side):

```bash
ai-sandbox start . --instance vscode-a
ai-sandbox start . --instance vscode-b
```

Open an interactive shell in the sandbox:

```bash
ai-sandbox shell .
```

The shell prompt now includes a clear `AI-SANDBOX` marker, project name, directory, and Git branch/status (Starship-based, matching the host `tom_shell.nix` style).

Show logs from an existing sandbox container:

```bash
ai-sandbox logs .        # one-shot
ai-sandbox logs . -f     # follow
```

Override the flake location:

```bash
ai-sandbox start . --flake /path/to/flake.nix
ai-sandbox start . --flake /path/to/flake-root
ai-sandbox warm . --flake ../some/other/flake-project
```

The workspace is still the first positional directory. `--flake` only changes which flake gets used for `nix develop`.

Override network mode (default is `host` for localhost OAuth callback compatibility):

```bash
ai-sandbox start . --network host
ai-sandbox start . --network bridge
```

## Recommended NixOS integration

Put this whole folder somewhere in your NixOS repo, for example:

```text
modules/ai-sandbox/
  Dockerfile
  container-entrypoint.sh
  ai-sandbox
  ai-sandbox.nix
  README.md
```

Import the module from your system config:

```nix
{
  imports = [
    ./modules/ai-sandbox/ai-sandbox.nix
  ];

  programs.ai-sandbox.enable = true;
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch --flake .
```

After that, `ai-sandbox` is available everywhere.

## Direnv usage in projects

Do **not** auto-launch the container from `direnv`. That gets annoying fast.

Use `direnv` to expose helper aliases instead.

Example `.envrc`:

```bash
use flake

alias sandbox-start='ai-sandbox start .'
alias sandbox-shell='ai-sandbox shell .'
alias sandbox-warm='ai-sandbox warm .'
```

If your flake is elsewhere:

```bash
export AI_SANDBOX_FLAKE_OVERRIDE="../nix/flake.nix"
alias sandbox-start='ai-sandbox start . --flake "$AI_SANDBOX_FLAKE_OVERRIDE"'
alias sandbox-shell='ai-sandbox shell . --flake "$AI_SANDBOX_FLAKE_OVERRIDE"'
alias sandbox-warm='ai-sandbox warm . --flake "$AI_SANDBOX_FLAKE_OVERRIDE"'
```

Then run:

```bash
direnv allow
sandbox-warm
sandbox-start
```

## Notes

- The sandbox still has X11 access. That is the weakest part of this design.
- The repo is mounted read/write on purpose.
- Host `$HOME` is not mounted.
- Host `/nix` is not mounted.
- The shared bind-mounted storage makes repeated launches much faster after the first warmup.
- Storage defaults to `~/.cache/ai-sandbox/{home,nix}` and is directly manageable as your user on the host.
- `ai-sandbox start/shell/warm` now auto-register a host URL handler for `vscode://` and `vscode-insiders://` so OAuth callbacks (for example GitHub login) route back into the running sandbox container.
- Network mode defaults to `host`, which makes `http://localhost:<port>/...` OAuth callbacks work generically across services because host browser localhost and container localhost are shared.
