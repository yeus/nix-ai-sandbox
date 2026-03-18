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
- uses one shared Podman volume for `/nix`
- uses one shared Podman volume for `/home/dev`
- mounts only the current project into `/workspace`
- if a flake is available, launches via `nix develop`
- if no flake is available, launches plain VS Code / plain shell

## Commands

Build/update the base image:

```bash
ai-sandbox build-base
```

Warm the current project flake into the shared `/nix` volume:

```bash
ai-sandbox warm .
```

Start VS Code for the current directory:

```bash
ai-sandbox start .
```

Open an interactive shell in the sandbox:

```bash
ai-sandbox shell .
```

Override the flake location:

```bash
ai-sandbox start . --flake /path/to/flake.nix
ai-sandbox start . --flake /path/to/flake-root
ai-sandbox warm . --flake ../some/other/flake-project
```

The workspace is still the first positional directory. `--flake` only changes which flake gets used for `nix develop`.

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
- The shared `/nix` volume makes repeated launches much faster after the first warmup.
