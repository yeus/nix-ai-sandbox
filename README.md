# AI sandbox for Podman + real VS Code + project flakes

Run VS Code and AI coding agents inside an isolated container, while keeping your development environment defined by your project flake.

This is the flat-folder version and is intended to be shareable via `git subtree`.

Files in this folder:

- `Dockerfile`
- `container-entrypoint.sh`
- `ai-sandbox`
- `ai-sandbox.nix`
- `README.md`

## Why this exists

With modern AI workflows, the bigger risk is often not just CLI tools, but VS Code plugins.

Coding-agent extensions can:
- execute shell commands
- modify your repository
- access tokens and credentials

In many cases you do not fully know what they do, and some are not even open source.

Even if a tool sandboxes parts of its execution, VS Code itself still usually runs on your host machine.

`ai-sandbox` takes a different approach:
- VS Code runs inside a container
- extensions run inside that container
- your host `$HOME` is not mounted
- your host `/nix` is not mounted
- the actual development environment still comes from your project `flake.nix`

So instead of trusting every coding-agent plugin, you isolate the whole editor environment it runs in.

## What it does

- builds one global Ubuntu image with real Microsoft VS Code and Nix
- uses bind-mounted host directories for `/nix` and sandbox home (defaults: `~/.cache/ai-sandbox/nix` and `~/.cache/ai-sandbox/home`)
- mounts the current project at `/workspace`
- if the project is a Git submodule, mounts the top superproject at `/workspace` and opens the submodule path inside it (preserves nested submodule `.git` path resolution)
- if a flake is available, launches via `nix develop`
- if no flake is available, launches plain VS Code / plain shell
- supports multiple concurrent containers per workspace (auto instance names, optional `--instance`)

In practice, that means:

- no per-project container config is required
- you can just run `ais` or `ai-sandbox` inside a flake-enabled repository
- the sandbox reuses a shared `/nix` cache across projects
- VS Code, extensions, and coding agents run inside the container instead of directly on your host

## Why this differs from Dev Containers

Dev Containers are mainly about reproducible development environments.

This project is more specifically about running **VS Code itself** in a sandboxed container, which makes VS Code extensions and coding-agent plugins much safer to use.

| Aspect | ai-sandbox | Dev Containers |
|-------|----------------|----------------|
| Goal | isolate VS Code + agent plugins | reproducible dev environments |
| Env definition | `flake.nix` via `nix develop` | `devcontainer.json` (+ Docker / Compose) |
| Per-project config | none needed | usually required |
| Editor runs | inside container | on host |
| Plugin isolation | yes | usually no |
| Cache reuse | shared `/nix` store | Docker layers |
| Multi-service setup | no | yes |
| Portability | mostly Linux/Nix | cross-platform |

If your main concern is “I want to use coding-agent plugins without giving them direct access to my host editor session”, this is a better fit than normal devcontainers.

If your main concern is standardized team environments across platforms and tools, devcontainers are the more standard choice.

## Commands

Build/update the base image:

```bash
ai-sandbox build-base
````

Rebuild the base image from scratch (remove old image tag first, keep storage dirs):

```bash
ai-sandbox rebuild
```

Reset sandbox storage (clear `~/.cache/ai-sandbox/nix` and `~/.cache/ai-sandbox/home` by default):

```bash
ai-sandbox reset-storage
```

Repair shared ai-sandbox Nix cache in place (verify/repair store paths, no delete):

```bash
ai-sandbox repair-nix
```

Warm the current project flake into the shared `/nix` storage directory:

```bash
ai-sandbox warm .
```

Start VS Code for the current directory:

```bash
ai-sandbox start .
```

By default, `start` streams startup logs (including flake/Nix setup) and auto-detaches once VS Code launch begins.

Start and continue following logs even after VS Code launch:

```bash
ai-sandbox start . --logs
```

Start with a stable instance suffix (useful for multiple VS Code windows/workspaces side by side):

```bash
ai-sandbox start . --instance vscode-a
ai-sandbox start . --instance vscode-b
```

Each sandbox instance now uses a hybrid VS Code profile model (details below).

If you do not pass `--instance`, ai-sandbox now uses a stable default instance name per workspace so VS Code profile state is preserved across relaunches. If that default instance is already running, ai-sandbox automatically falls back to a unique instance suffix.

Open an interactive shell in the sandbox:

```bash
ai-sandbox shell .
```

The shell prompt includes a clear `AI-SANDBOX` marker, project name, directory, and Git branch/status.

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

## Typical usage

In a flake-enabled repository:

```bash
cd your-project
ai-sandbox warm .
ai-sandbox start .
```

Or, if you want a shell instead of VS Code:

```bash
ai-sandbox shell .
```

If you have the short alias installed:

```bash
cd your-project
ais
```

That is the intended workflow: enter a project, run `ais`, and get VS Code inside a container with the project dev environment coming from the flake.

## VS Code Profile Model (Hybrid)

When multiple independent VS Code processes run in different containers, sharing one full `--user-data-dir` can break Chromium webview/service-worker state.

To keep concurrent containers stable while preserving desktop-like behavior, ai-sandbox uses:

- per-instance `--user-data-dir` internals at `/sandbox-home/.vscode-data/instances/<workspace-hash>-<instance>`
- shared user config at `/sandbox-home/.vscode-shared-user`:
  - `settings.json`
  - `keybindings.json`
  - `tasks.json`
  - `locale.json`
  - `snippets/`
- shared extensions at `/sandbox-home/.vscode-extensions/shared`

Practical behavior:

- settings/keybindings/snippets stay consistent across instances
- extensions installed in one instance appear in all instances
- webview/process/cache internals remain isolated per instance to avoid cross-container collisions

Shell behavior note:

- ai-sandbox shell startup does **not** source `$HOME/.bashrc` by default (to avoid host/sandbox prompt hook conflicts)
- set `AI_SANDBOX_SOURCE_USER_BASHRC=1` if you explicitly want to opt back in

## Troubleshooting

If only the first sandbox VS Code window works and later ones show:

`Error loading webview: Could not register service worker: InvalidStateError`

then clear stale shared VS Code profile data from older ai-sandbox runs and restart:

```bash
ai-sandbox reset-storage
```

Then launch separate instances again (for example with different `--instance` names).

If `nix develop` fails with missing `/nix/store/...` files, run:

```bash
ai-sandbox repair-nix
```

This verifies and repairs the shared ai-sandbox `/nix` cache without deleting it.

If you recently changed ai-sandbox scripts, rebuild and restart containers so the new entrypoint is used:

```bash
ai-sandbox rebuild
```

If shell prompts look corrupted (for example visible `\[\]` markers), leave `AI_SANDBOX_SOURCE_USER_BASHRC` unset (default `0`) or explicitly disable it:

```bash
export AI_SANDBOX_SOURCE_USER_BASHRC=0
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

## Share this folder as a Git subtree

Create a split branch from this repo and push it to a dedicated remote:

```bash
git subtree split --prefix=ai-sandbox --branch ai-sandbox-split
git push git@github.com:<org>/<ai-sandbox-repo>.git ai-sandbox-split:main
```

Consume it from another repository:

```bash
git subtree add --prefix=modules/ai-sandbox git@github.com:<org>/<ai-sandbox-repo>.git main --squash
```

Pull updates later:

```bash
git subtree pull --prefix=modules/ai-sandbox git@github.com:<org>/<ai-sandbox-repo>.git main --squash
```

Push local subtree changes back to the subtree remote:

```bash
git subtree push --prefix=ai-sandbox git@github.com:<org>/<ai-sandbox-repo>.git main
```

## Direnv usage in projects

Do not auto-launch the container from `direnv`. That gets annoying fast.

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

* This has only been tested with Nix Home Manager so far.
* This has been tested with an X.org server; it will likely not work with Wayland yet.
* Contributions are welcome.
* The sandbox still has X11 access. That is the weakest part of this design.
* The repo is mounted read/write on purpose.
* Host `$HOME` is not mounted.
* Host `/nix` is not mounted.
* The shared bind-mounted storage makes repeated launches much faster after the first warmup.
* Storage defaults to `~/.cache/ai-sandbox/{home,nix}` and is directly manageable as your user on the host.
* `ai-sandbox start`, `shell`, and `warm` auto-register a host URL handler for `vscode://` and `vscode-insiders://` so OAuth callbacks (for example GitHub login) route back into the running sandbox container.

## Security model

This is not a hardened sandbox.

It improves isolation in a very practical way, especially for VS Code extensions and coding agents, but it is not equivalent to a VM or a strict security boundary.

The main tradeoff is convenience vs isolation:

* real VS Code runs in the container
* host home and host `/nix` stay out
* but X11 access, writable workspace mounts, and optional host networking still exist

So the right way to think about this is:

> a practical containment layer for AI-assisted development

not

> a perfect sandbox

## Summary

If you install AI coding agents directly into VS Code on your host, you are effectively trusting arbitrary plugin code with a lot of access.

This project gives you a much more practical setup:

* open a flake-based repo
* run `ais`
* get real VS Code inside a container
* keep your dev environment Nix-native
* reuse cached dependencies across projects
* reduce the blast radius of VS Code plugins and coding agents
