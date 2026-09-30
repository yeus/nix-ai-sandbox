# AI sandbox for Podman + real VS Code + project flakes

Run VS Code and AI coding agents inside an isolated container, while keeping your development environment defined by your project flake.

This is the flat-folder version and is intended to be shareable via `git subtree`.

Files in this folder:

- `Dockerfile`
- `container-entrypoint.sh`
- `ai-sandbox-agent-config.sh`
- `ai-sandbox`
- `ai-sandbox.nix`
- `skills/`
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
- mounts `/tmp/ais/<container-name>` from the host at `/tmp` inside each container
- if the project is a Git submodule, mounts the top superproject at `/workspace` and opens the submodule path inside it (preserves nested submodule `.git` path resolution)
- if a flake is available, launches via `nix develop`
- if no flake is available, launches plain VS Code / plain shell
- supports multiple concurrent containers per workspace (auto instance names, optional `--instance`)

In practice, that means:

- no per-project container config is required
- you can just run `ais` or `ai-sandbox` inside a flake-enabled repository
- the sandbox reuses a shared `/nix` cache across projects
- VS Code, extensions, and coding agents run inside the container instead of directly on your host

Temporary files created inside a sandbox are visible on the host under
`/tmp/ais/<container-name>/`. Each container has its own directory, so
unrelated workspaces and instances do not share `/tmp`. The `/tmp/ais` parent
is user-owned and private (`0700`); each mounted directory has normal `/tmp`
permissions (`1777`). These files persist while the host keeps them and are
not removed by `ai-sandbox` when a container stops. Treat them as potentially
sensitive, and do not publish them without reviewing their contents.

Existing containers keep their original mounts. Recreate a container before
expecting its `/tmp` to appear on the host. `ai-sandbox reset-container .`
removes all containers for the current workspace, but does not remove
`/tmp/ais` files. This also discards any state stored only in those containers.

## Everyday use

Run `ais` on the host from the repository you want to work on. It starts VS
Code in that repository's sandbox. For a disposable interactive shell, use
`ais shell .`. Both commands use the current directory as the workspace; pass
a different directory explicitly when needed.

The MCP connection is separate from the editor container. Use `ais mcp --local`
for loopback Streamable HTTP, `ais mcp --publish cloudflare` for a stable
outbound HTTPS endpoint behind NAT, or keep using `ais mcp --tunnel` for the
OpenAI Secure MCP Tunnel. Each mode starts a dedicated MCP container for the
same workspace; VS Code does not need to be running.

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

Build/update the base image only:

```bash
ai-sandbox build-base
````

Build the image and then install the default user-space agents and VS Code:

```bash
ai-sandbox build .
```

Install or refresh default user-space software without rebuilding:

```bash
ai-sandbox install .
ai-sandbox install . --force
ai-sandbox install . --only codex
ai-sandbox install . --only opencode
ai-sandbox install . --only pi
ai-sandbox install . --only vscode
```

Inside sandbox terminals, `apt-get` and `apt` are available directly. They are
wrapped to run with root privileges for package-management commands.

Rebuild the base image without removing existing containers or storage:

```bash
ai-sandbox rebuild
```

The rebuild uses `--no-cache` and only replaces the image tag after a
successful build. A running sandbox keeps using its already-created image, so
agents can continue working while the rebuild runs. Remove and recreate a
container explicitly with `ai-sandbox reset-container` when you are ready for
it to use the new image.

Remove persistent sandbox containers (keep home/nix storage):

```bash
ai-sandbox reset-container .
ai-sandbox reset-container --all
```

Reset sandbox storage (clear `~/.cache/ai-sandbox/nix` and `~/.cache/ai-sandbox/home` by default):

```bash
ai-sandbox reset-storage
```

Repair shared ai-sandbox Nix cache in place (verify/repair store paths, no delete):

```bash
ai-sandbox repair-nix
```

Prune stopped sandbox containers, unused ai-sandbox image layers, and old
unreferenced paths from the shared Nix store:

```bash
ai-sandbox prune
```

If a sandbox is still running, its container is kept while Nix and image cleanup
continues. To explicitly stop and remove all ai-sandbox containers before
garbage collection, use:

```bash
ai-sandbox prune --force
```

Running cleanup while containers remain active can keep some paths rooted; use
`--force` when you want the most complete and isolated collection pass.

The current tagged image and sandbox home are kept. Image pruning is limited to
unused images labeled `ai-sandbox=true`, plus legacy dangling images whose
recorded Podman name matches the configured sandbox image.

Run pruning from the host shell where Podman is available. The sandbox itself
does not expose the host Podman socket or the host storage paths.

Sync shared global instructions (sandbox-wide, not project-local):

```bash
ai-sandbox agents pull
ai-sandbox agents push
ai-sandbox agents reset
ai-sandbox agents clear
ai-sandbox agents pull --file ./AGENTS.md --force
```

Inside sandbox terminals, `ai-sandbox` is available as an alias to
`/workspace/ai-sandbox/ai-sandbox`, so these `agents` commands can be run there too.

Sync shared user-owned skills:

```bash
ai-sandbox skills pull
ai-sandbox skills push
ai-sandbox skills push --dir ./skills --force
```

The shared directory is `~/.agents/skills`. Sync rejects a source containing
`.system`, so Codex-managed built-in skills are not copied or overwritten.

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

Start code-server in a persistent, browser-accessible sandbox instead of
desktop VS Code:

```bash
ai-sandbox serve .
```

`serve` uses the same workspace mount and `nix develop` environment as
`start`, but it does not grant the container access to X11, DRI, Xauthority,
or the host D-Bus session. It lazily installs code-server into the persistent
sandbox home and prints its stable loopback URL and an SSH tunnel command.

From the client computer or an SSH client with local port forwarding:

```bash
ssh -N \
  -L 18080:127.0.0.1:18080 \
  user@remote-host
```

Use the actual stable port printed by `serve`, then open the corresponding
`http://127.0.0.1:<port>` URL. The endpoint has no additional password because
it listens only on remote loopback; SSH authentication is the access boundary.
Bridge networking is intentionally rejected for this mode.

Choose a port explicitly when first creating the server, or while it is
stopped:

```bash
ai-sandbox serve . --port 18123
```

Stop the server without removing its persistent container or editor data:

```bash
ai-sandbox serve . --stop
```

Browser-editor profiles and extensions are separate from desktop VS Code
profiles because code-server extension compatibility differs. Repository
`.vscode` configuration remains shared through the workspace mount.

## Workspace MCP

### Transport choices

`ais mcp` supports three independent transports. Only one may run for a
workspace at a time:

- `ais mcp --tunnel` keeps the existing OpenAI Secure MCP Tunnel over stdio.
- `ais mcp --local` exposes native Winx Streamable HTTP only on host loopback.
- `ais mcp --publish cloudflare` exposes Streamable HTTP through a stable
  remotely managed Cloudflare tunnel. `cloudflare-quick` is available only as
  a temporary development shortcut.

### Persistent connection identities

The first MCP workspace registered on a host is assigned `mcp1`, the next
`mcp2`, and so on. The connection identity is stored in the same host-only MCP
state as its credentials and survives container restarts:

```text
Connection: mcp1
Endpoint:   ...
```

You can choose the name on first start instead:

```bash
ais mcp --local --connection taskyon
ais mcp --publish cloudflare --connection joulios
```

Connection names are unique across the host secret store and cannot silently
move between workspaces. A later start from the same workspace reuses the saved
identity even when `--connection` is omitted.

The identity is separate from the transport. Local HTTP also reuses its stable
host port, while a named Cloudflare publisher reuses its persisted public URL
and tunnel credentials. This is the register-once path for remote services:
`mcp1`, `mcp2`, or a custom connection name continues to identify the same
workspace endpoint after `ais mcp --stop` and a later restart. Quick Tunnels are
the explicit exception because Cloudflare assigns a new temporary hostname.

The OpenAI tunnel ID is persistent workspace identity as well: each workspace
remembers its own ID under the host-only secrets tree, while the shared runtime
API key stays in Secret Service. Different workspaces can therefore run
separate tunnels in parallel without overwriting each other's registration.


HTTP modes use a persistent per-workspace bearer API key. Show it with:

```bash
ais mcp --show-key
```

Configure a compatible MCP client with the printed endpoint and:

```text
Authorization: Bearer <api-key>
```


This is static bearer authentication rather than OAuth. It works with MCP
clients that let you supply an authorization token or HTTP credential. For
example the OpenAI Agents API supports reusable HTTP credentials and the
Anthropic Messages API accepts an MCP `authorization_token`. ChatGPT custom
apps currently do not accept a caller-provided API key for authenticated MCP
apps; keep using `ais mcp --tunnel` for that ChatGPT path unless an OAuth-capable
edge is added later.
The key is generated once and stored by default under
`~/.cache/ai-sandbox/secrets/mcp/<workspace-hash>/bearer-token`. Override the
root with `AI_SANDBOX_SECRETS_STORAGE` or the Home Manager option
`programs.ai-sandbox.secretsStorage`. This directory is host-only: it is not
mounted into the MCP container and is deliberately separate from the sandbox
home and Nix stores. The key survives MCP container replacement and
`reset-storage`; rotate it by stopping MCP and replacing or removing that
workspace token file.

Winx receives the key through a temporary `0600` token file at startup. Winx
loads the credential before accepting requests and the temporary copy is then
deleted, so the connected AI cannot recover its own server credential through
Bash. Tokens are never passed as process arguments or URL query parameters.

### Local HTTP

Start a loopback-only endpoint:

```bash
ais mcp --local
```

`ais` assigns a stable free host port per workspace and prints the resulting
`http://127.0.0.1:<port>/mcp` URL. An explicit port is also supported:

```bash
ais mcp --local --port 19123
```

The Winx listener runs inside the isolated MCP network namespace and Podman
publishes it only to host `127.0.0.1`. HTTP MCP intentionally rejects host
networking. Different workspaces have separate containers, API keys, runtime
state, and host ports, so multiple workspace MCPs can run on the same machine.

### Stable Cloudflare publishing

For a machine behind NAT, create a remotely managed Cloudflare Tunnel and
configure a public hostname for it whose service/origin is
`http://localhost:18081`. Then start:

```bash
ais mcp --publish cloudflare \
  --public-url https://mcp.example.com
```

On first use `ais` securely asks for the Cloudflare tunnel token and the public
base URL for that persistent connection identity. It stores the tunnel token
and public base URL beside the workspace API key in the host-only secret store.
Later starts reuse the connection identity, URL, tunnel configuration, and API
key, so a remote AI service only needs to be configured once.

No router port is opened and no MCP port is published on the host. Both Winx
and `cloudflared` run in the dedicated MCP container; `cloudflared` initiates
the connection outward through NAT. Winx remains on container loopback and
validates the configured public Host authority before processing MCP requests.

For a disposable URL instead:

```bash
ais mcp --publish cloudflare-quick
```

Quick Tunnel URLs change between launches and therefore are not suitable for
register-once integrations.

Use the normal lifecycle commands for every transport:

```bash
ais mcp --status
ais mcp --status --json
ais mcp --stop
```

`SYSTEM_DEFINITION.csv` tracks these MCP capabilities and their implementation
and verification paths. `tests/system-definition-test.sh` checks the matrix for
duplicate IDs and stale file references.

### OpenAI Secure MCP Tunnel

1. From the host, go to the repository you want ChatGPT to access. The current
   directory becomes the workspace mounted at `/workspace` inside the MCP
   container. You can also pass a workspace path, for example
   `ais mcp /path/to/repo --tunnel`.
2. [Create an OpenAI Secure MCP Tunnel](https://platform.openai.com/settings/organization/tunnels).
   Creating one requires Tunnels Read + Manage. Associate it with the ChatGPT
   workspace where you will create the app; association with only a Platform
   organization is not enough for that workspace to list it.
3. [Create a runtime API key](https://platform.openai.com/settings/organization/api-keys)
   with Tunnels Read + Use. Start the sandbox MCP connection:

   ```bash
   ais mcp --tunnel
   ```

   On first use, `ais` asks for the tunnel ID and runtime key. In an
   interactive terminal it prints the locally known tunnels with a stable
   number, the last four characters of the ID, the operator-visible tunnel name
   when it has been seen before, and whether another local workspace is running
   that tunnel right now. Select an entry, enter `n` to type a new ID, and
   confirm; the same prompt always prints the tunnel management page and the
   ChatGPT/Codex connector settings link. The runtime API key is saved in the
   desktop Secret Service through `secret-tool`. The tunnel ID is not a secret:
   it is saved as workspace identity state under the host-only AI Sandbox
   secrets tree, so each workspace remembers its own tunnel. You do not need to
   export a control-plane key or put either value in a project file. Wait until
   the status says `Tunnel Health: READY`, then leave this terminal running
   while you connect ChatGPT.

4. In ChatGPT, enable **Developer mode** under **Settings → Security and login**
   if your account or workspace permits it. Open **Plugins**, select **+** to
   create an MCP app, choose **Tunnel** under Connection, and select or paste
   the same tunnel ID. Choose **No auth** for this Winx MCP server: it does not
   implement app-level OAuth. The runtime API key belongs only in the `ais`
   prompt, never in the ChatGPT app form. Anyone allowed to use this app can
   call its sandboxed Bash and file tools, so share it only with trusted users.
5. In a new ChatGPT conversation, add the app from the tools menu and ask it to
   use the sandbox to inspect or change this repository. Winx exposes a Bash
   shell and file tools inside the dedicated MCP container.

OpenAI's [Secure MCP Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
and [ChatGPT app connection guide](https://developers.openai.com/plugins/deploy/connect-chatgpt)
describe the Platform and ChatGPT sides of these steps. The tunnel is for
private developer-mode connections; it does not publish a public MCP URL or
make this app eligible for public plugin submission.

### While it is running

The foreground command starts with Winx output hidden. Press `v` to show tool
activity and shell output in the same terminal; press `v` again to hide it.
Available shell scrollback is shown when you turn output back on. Tool activity
shows names and outcomes without command text or file contents, while shell
output may include commands and their results. Press `Ctrl-C` to stop the
tunnel and its dedicated MCP container.

For background operation instead, run:

```bash
ais mcp --tunnel --detach
```

Later `ais mcp --tunnel` invocations show the picker again, with the saved ID
as the default, so no Secret Service tunnel entry and no ChatGPT
re-registration are needed when you confirm it. Pass a tunnel ID with
`--tunnel TUNNEL_ID` to skip the picker for scripts and non-interactive runs.
Because each workspace keeps its own tunnel ID, separate projects can run their
own tunnels and ChatGPT apps in parallel without overwriting each other's
registration.

Selecting a tunnel that another local workspace is running triggers a takeover
question; after confirmation that workspace's tunnel is stopped before this one
connects. This matters because OpenAI supports only one active `tunnel-client`
process per tunnel ID for a stdio MCP server: overlapping instances can send
initialize and tool calls to different machines. Only local containers can be
detected and stopped; a runtime key cannot list remote runtimes, so a tunnel
already served by another host cannot be detected from here. The picker's names
come from the local registry and are refreshed through the tunnel client's
read-only `admin tunnels get` lookup after each successful start. That lookup
can read a known tunnel ID, but listing, creating, and deleting tunnels require
a Platform admin key and Tunnels Manage, so tunnel creation stays manual.

To inspect health or stop a detached tunnel, run:

```bash
ais mcp --status
ais mcp --status --json
ais mcp --stop
```

To list Winx shell sessions or follow one specific thread from another
terminal, run:

```bash
ais mcp --sessions
ais mcp --attach THREAD_ID
```

If ChatGPT says **No tunnels yet**, check the tunnel's ChatGPT workspace
association and the app creator's Tunnels Read + Use permission, then refresh
the list. If the app cannot discover tools or make calls, leave
`ais mcp --tunnel` running and check `ais mcp --status` or the printed local
Tunnel UI URL for `READY` health. An active tunnel cannot be switched to
another ID; stop it before starting with a different one.

### Container boundary

The pinned, checksum-verified tunnel client launches pinned Winx over stdio.
Winx exposes a persistent Bash shell plus file reading and editing tools rooted
at `/workspace`. The tunnel key is removed from Winx's environment before it
starts. The MCP container has its own persistent home directory. It uses
private networking by default: Podman uses a bridge when rootful and its
rootless backend (such as `pasta`) when rootless. The MCP container cannot see
the normal sandbox home or host loopback services. The workspace and Nix
storage remain mounted read/write so commands can work.

If MCP needs host-local services such as a dev server listening on
`127.0.0.1`, opt into host networking when starting it:

```bash
ais mcp --tunnel --network host
```

This gives MCP's Bash access to services on the host network. Private
networking remains the default. Podman fixes a container's network mode when
it is created; to switch an existing MCP container, stop MCP and remove that
container before restarting with the other mode.

The isolated home is the secure default because the remote AI drives Winx
through Bash: the normal sandbox home stores agent OAuth credentials
(`~/.codex/auth.json`, `~/.pi/agent/auth.json`), provider configuration, and
tool state that a remote model must not read. When you intentionally want the
Winx agent to share tools, caches, and configuration with the normal sandbox
home, opt in explicitly:

```bash
ais mcp --tunnel --share-home
```

This mounts the full sandbox home into the MCP container and prints a warning
listing the exposure. The MCP agent can then read stored credentials and modify
agent configuration that other sandboxes load. The mode is recorded in MCP
status metadata, and the next start returns to the isolated home unless the flag
is passed again. Stop MCP before switching home modes.

Winx asks the calling AI to read the workspace's `AGENTS.md` and the Codex
instructions at `/sandbox-home/.codex/AGENTS.md` after initialization. If the
normal sandbox has a global Codex `AGENTS.md`, the dedicated MCP container
mounts that one file read-only at the same path; otherwise its separate home
uses the image's default copy.
Nested workspace `AGENTS.md` files should be read when relevant. These are MCP
guidance for the calling AI, not enforced rules.

To control an emulator through the host adb server, give the dedicated MCP
container Android access:

```bash
ais mcp --tunnel --android
```

This keeps MCP's separate home and uses host networking so
`ADB_SERVER_SOCKET=tcp:127.0.0.1:5037` reaches the same adb server as the
normal Android sandbox. It does not need KVM to control an emulator that is
already running.

To start an emulator inside the MCP container itself, use
`ais mcp --tunnel --emulator`. This also mounts the Android state directory and
passes `/dev/kvm`; `--android-gpu` optionally passes `/dev/dri`. The flag does
not start an AVD automatically. Winx starts in the project's Nix dev shell
when one is available, so its commands can use the same Android tools as
`ais shell --emulator`. Stop MCP before changing Android modes.

Installation, tunnel state, and privacy-safe usage logs stay under the
dedicated MCP home in sandbox storage. No MCP configuration is added to the project.
Submodule workspaces whose normal sandbox mount includes a parent repository
are rejected; start MCP from the mounted top-level repository. The pinned Winx
release currently supports Linux x86-64; other architectures fail clearly.

On first use after the old `gpt-repo-mcp` integration, the launcher stops the
old MCP container before connecting Winx.

Open an interactive shell in the sandbox:

```bash
ai-sandbox shell .
```

By default, `start` and `exec` reuse persistent per-workspace containers
(`instance=default`) instead of always using disposable `--rm` containers.
`shell` starts a fresh disposable container each time so interactive sessions stay isolated.

Run a command directly in shell mode (flake-aware):

```bash
ai-sandbox shell . -- codex
ai-sandbox shell codex
```

Run any command in the sandbox (auto-reuses a running workspace sandbox when available):

```bash
ai-sandbox exec . -- codex --version
ai-sandbox exec . -- ai-sandbox-default-install --only codex --force
```

With the short alias, unknown commands are routed to sandbox exec automatically:

```bash
ais codex --version
ais ai-sandbox-default-install --only codex --force
ais code --version
```

The shell prompt includes a clear `AI-SANDBOX` marker, project name, directory, and Git branch/status.

Show logs from an existing sandbox container:

```bash
ai-sandbox logs .        # one-shot
ai-sandbox logs . -f     # follow
```

Open a file in the running sandbox VS Code from the host:

```bash
ai-sandbox open-in-editor /abs/path/to/file.ts 1062 55
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

Automatic network healing for long-running containers (default enabled):

```bash
ai-sandbox start . --auto-reconnect
ai-sandbox start . --no-auto-reconnect
ai-sandbox start . --auto-reconnect-interval 8
```

Diagnose or repair an already running sandbox after host network changes:

```bash
ai-sandbox doctor-net .
ai-sandbox reconnect-network .
```

## Android testing

Android support is opt-in. The generic image remains free of Android SDK
files, `adb`, emulator binaries, and system images. A project that needs
Android testing should expose its Android tools from its own `nix develop`
shell. The shell should provide `platform-tools` for controller mode and the
emulator plus its platform and system image for in-container mode.

The canonical in-container flag is `--emulator`; `--android-emulator` is
accepted as a long-form alias.

The project flake can use the current nixpkgs Android API, including
`composeAndroidPackages` with `includeEmulator = true` where that option is
available. SDK files should remain managed by that flake; do not copy them into
the Nix store manually.

For an `x86_64-linux` project, the package definition can be shaped like this
inside that project’s own flake:

```nix
let
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "35" ];
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ "x86_64" ];
    includeEmulator = true;
  };
in
pkgs.mkShell {
  packages = [
    androidComposition.platform-tools
    androidComposition.emulator
    androidComposition.androidsdk
  ];
}
```

Choose a platform version available in the pinned nixpkgs revision. If that
revision uses the conditional form, use `includeEmulator = "if-supported"` and
keep the shell on `x86_64-linux` for the emulator.

### Host-side emulator (recommended)

Run the emulator on the NixOS/Linux host. Start the host adb server yourself
and keep it on loopback:

```bash
adb start-server
ss -ltn | grep 127.0.0.1:5037
adb devices
```

Start an emulator with a graphical window if desired, or use the headless
configuration for adb-based tests:

```bash
emulator -avd <avd-name> \
  -no-window -no-audio -no-boot-anim
```

The adb server must not be started with an all-interface bind such as
`adb -a`. The sandbox never publishes adb, starts a host adb server, or asks
Podman to expose port 5037.

Start the controller sandbox with host networking:

```bash
ai-sandbox start . --android
```

The same adb-enabled shell is available for test commands:

```bash
ai-sandbox shell . --android
ai-sandbox exec . --android -- adb devices
```

Inside this mode, adb receives:

```text
ADB_SERVER_SOCKET=tcp:127.0.0.1:5037
```

Host networking is required because `127.0.0.1` must refer to the host adb
server. This mode does not pass KVM, `/dev/dri`, or any other emulator device.
It can still start when the project shell does not provide `adb`; the Android
diagnostic command reports that missing dependency when requested.

Check the complete controller path with:

```bash
ai-sandbox android-doctor .
```

The command runs in a temporary sandbox and reports the project-shell adb
path, host adb reachability, and visible devices. It exits nonzero when adb,
the server, or a device is unavailable.

### In-container emulator (explicit hardware mode)

Use this only when the emulator itself must run inside Podman. The host must
provide an accessible KVM device:

```bash
test -e /dev/kvm
ai-sandbox android-doctor . --emulator
```

The equivalent long-form spelling is:

```bash
ai-sandbox android-doctor . --android-emulator
```

If `/dev/kvm` is unavailable, the launcher exits without starting Podman and
explains how to use `--android` with a host emulator. It does not silently use
slow software emulation.

The launcher passes only `/dev/kvm` and the existing keep-groups setting:

```text
--device=/dev/kvm
--group-add=keep-groups
```

It never uses `--privileged` and never mounts the host `/dev` directory. Add
GPU access only when explicitly needed:

```bash
ai-sandbox shell . --emulator \
  --android-gpu -- emulator -avd <avd-name> \
  -no-window -no-audio -no-boot-anim
```

`--android-gpu` adds `/dev/dri`; it is rejected unless `--emulator` is also
present. Headless operation does not need Wayland, X11, or `/dev/dri`.

The emulator mode itself enables the permissions and environment; it does not
choose an AVD or start a long-running emulator automatically. Start it from an
Android-enabled shell or command as shown above, then run the normal test
command in another Android-enabled shell.

### Persistent Android state

Android writable state is stored on the host at:

```text
~/.cache/ai-sandbox/android
```

Override it with `AI_SANDBOX_ANDROID_STATE_DIR` and use an absolute host path.
The container mounts this directory at `/android-state` and sets:

```text
ANDROID_USER_HOME=/android-state/user
ANDROID_AVD_HOME=/android-state/avd
ANDROID_EMULATOR_HOME=/android-state/emulator
```

The SDK binaries and system image remain supplied by the project flake; the
cache stores writable user metadata and AVD state. `ai-sandbox reset-storage`
also removes this Android state directory.

### KVM and security

KVM passthrough gives a container access to the host virtualization device.
That is materially more sensitive than the normal sandbox and should remain
an explicit choice. The launcher requires `/dev/kvm`, preserves the host
supplementary groups needed for access, and passes no broad privilege flag.
GPU access is a separate explicit choice. Prefer the host-emulator controller
mode whenever the emulator does not need to run inside the container.

## Typical usage

In a flake-enabled repository:

```bash
cd your-project
ai-sandbox warm .
ai-sandbox start .
```

Important: `ai-sandbox start` launches VS Code from `nix develop` when your project exports a default dev shell, so flake-provided tools and `shellHook` environment variables should be available inside VS Code and agent processes.

That does not replace project bootstrap steps. Repo-local tools such as `vue-tsc` often come from `node_modules/.bin`, Corepack shims, generated SDKs, or other files that only exist after you run the project initialization command inside the sandbox itself. If a tool is present in your normal dev shell but missing for Codex, the usual fix is to open a terminal in the sandboxed VS Code window and run the repo's setup step there first, for example `yarn install`, `pnpm install`, `npm install`, or a project-specific bootstrap command.

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

## Persistent Home, Shared Agent Resources, and Updates

Sandbox home is persisted in `~/.cache/ai-sandbox/home` by default (configurable), and is mounted at `/sandbox-home` inside containers.

- `ai-sandbox build`, `ai-sandbox build-base`, and `ai-sandbox rebuild` do not erase sandbox home.
- `ai-sandbox reset-storage` is the command that erases persisted home and nix storage.

`CODEX_HOME` is pinned to:

```bash
/sandbox-home/.codex
```

Global instructions are seeded once (if missing) to:

```bash
/sandbox-home/.codex/AGENTS.md
```

from image default:

```bash
/usr/local/share/ai-sandbox/default-AGENTS.md
```

OpenCode and Pi use symlinks to the same file:

```text
~/.config/opencode/AGENTS.md
~/.pi/agent/AGENTS.md
```

User-owned skills are seeded from the image's checked-in `skills/` directory
into `~/.agents/skills`. OpenCode and Pi discover that standard location
directly. Codex receives one symlink per user-owned skill in
`~/.codex/skills`, leaving its managed `.system` directory untouched.

This means global instructions and user skills persist on host storage and can
be modified from any workspace. Project-local `AGENTS.md` remains separate.

tycli is not installed by this repository and its source is not part of this
checkout. To join the same global layer, its resource loader must read:

```text
/sandbox-home/.codex/AGENTS.md
/sandbox-home/.agents/skills
```

Do not add environment variables or config keys unless tycli implements them;
setting an unused path would only make the integration appear to work.

ai-sandbox also ensures `~/.codex/config.toml` contains:

```toml
[sandbox_workspace_write]
writable_roots = ["/sandbox-home/.codex"]
```

so Codex started from `/workspace` can still edit global files in `CODEX_HOME`.

To fully disable default seeding and erase global Codex instructions:

```bash
ais bash -lc 'mkdir -p ~/.codex && touch ~/.codex/.disable_default_agents_seed && rm -f ~/.codex/AGENTS.md ~/.codex/AGENTS.override.md'
```

To re-enable default seeding later:

```bash
ais bash -lc 'rm -f ~/.codex/.disable_default_agents_seed'
```

Codex is installed in user space (`~/.npm-global`) and persisted in sandbox home:

```bash
ai-sandbox install . --only codex
ais codex --version
```

OpenCode and Pi are installed in the same user-space prefix:

```bash
ai-sandbox install . --only opencode
ai-sandbox install . --only pi
ais opencode --version
ais pi --version
```

VS Code runs from a user-space install in sandbox home:

```bash
ai-sandbox install . --only vscode --force
ais code --version
```

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

If you see `database disk image is malformed` for `/nix/var/nix/db/db.sqlite`:

1. Stop running ai-sandbox containers for this workspace.
2. Run `ai-sandbox repair-nix`.
3. If it still fails, run `ai-sandbox reset-storage` to recreate shared caches from scratch.

Recent ai-sandbox versions now seed `/nix` only once and avoid copying seeded Nix DB runtime files into a live cache, which reduces the chance of this corruption pattern.

If you changed the host launcher or its MCP scripts, reactivate the Home Manager
profile that imports `ai-sandbox.nix`. For this repository's `#tom` profile:

```bash
home-manager switch --flake .#tom
```

If you changed the Dockerfile or files copied into the container image, rebuild
the image. Existing containers keep their old image until you reset and
recreate them:

```bash
ai-sandbox rebuild
ai-sandbox reset-container .
```

To confirm home persistence across rebuild:

```bash
ais bash -lc 'echo ok > ~/.local/state/ai-sandbox-persist-check'
ai-sandbox rebuild
ais bash -lc 'cat ~/.local/state/ai-sandbox-persist-check'
```

If dev-server "open in editor" links (error overlays, stack traces, click-to-open file links) open host VS Code instead of the sandbox window:

```bash
ai-sandbox start .
LAUNCH_EDITOR=ais <your-dev-command>
```

This pattern is framework-agnostic and works for many stacks that honor `LAUNCH_EDITOR` through `launch-editor` style tooling (for example Vite apps like React/Vue/Svelte, Quasar CLI with Vite, and other dev servers that support `LAUNCH_EDITOR`).

Examples:

```bash
LAUNCH_EDITOR=ais npm run dev
LAUNCH_EDITOR=ais pnpm dev
LAUNCH_EDITOR=ais yarn dev
LAUNCH_EDITOR=ais quasar dev
```

This works because `ais` detects launch-editor style arguments (`<file> [line] [column]`) and forwards them to:

```bash
ai-sandbox open-in-editor <file> <line> <column>
```

If you prefer, `ai-sandbox-launch-editor` remains available and does the same forwarding.

If you do not use the Nix module helper package, create a tiny wrapper script and point `LAUNCH_EDITOR` to it:

```bash
#!/usr/bin/env bash
exec ai-sandbox open-in-editor "$@"
```

Then:

```bash
LAUNCH_EDITOR=/absolute/path/to/your-wrapper.sh <your-dev-command>
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
use flake ./packaging/nix

alias sandbox-start='ai-sandbox start .'
alias sandbox-shell='ai-sandbox shell .'
alias sandbox-warm='ai-sandbox warm .'
```

`ai-sandbox` also detects flake overrides from `.envrc` before startup:
- `use flake ./path/to/flake-root`
- `export AI_SANDBOX_FLAKE_OVERRIDE=./path/to/flake.nix`

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
* Security note: sandbox image grants passwordless `sudo` for `apt/apt-get/dpkg` to support in-sandbox package installs.

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
