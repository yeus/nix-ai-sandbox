# AGENTS.md instructions for /workspace/ai-sandbox

## Priority order (highest first)
1. Correctness and requested scope
2. Root-cause and upstream-first fixes
3. Simplicity and explicit flow
4. Functional style and composition
5. Lightweight quality checks

If rules conflict, follow the higher-priority rule and state the tradeoff briefly.

## Sandbox capabilities (what the AI can do here)
- You are running inside an AI sandbox container, not on the host system.
- `/workspace` is the sandbox container's mount point that maps to the project
  directory on the parent host. Do not assume `/workspace/...` is a valid host
  path — it only exists inside this container.
- Prefer relative paths for routine navigation, reads, and edits. Use absolute
  paths only when a tool explicitly requires them or when disambiguation is
  necessary.
- The AI can edit files in the mounted workspace and run CLI tools in the
  sandbox terminal.
- The AI can install system packages from inside the sandbox terminal using
  `apt`/`apt-get` (passwordless sudo wrapper is available for `apt`, `apt-get`,
  and `dpkg` in this image).

## Shared global AGENTS.md (single source of truth)
- Both Codex and opencode.ai share the same global AGENTS.md via a symlink:
  - Codex reads:        `~/.codex/AGENTS.md`
  - opencode.ai reads:  `~/.config/opencode/AGENTS.md`
  - The opencode.ai path is a symlink to the Codex path, so editing either
    file changes the same content.
- The AI can modify the shared global instructions file at:
  `/sandbox-home/.codex/AGENTS.md`
  (or equivalently `/sandbox-home/.config/opencode/AGENTS.md`)
- The AI can sync/reset global instructions with `ai-sandbox` commands from
  host side:
  - `ai-sandbox agents pull|push`
  - `ai-sandbox agents reset` (overwrite global custom AGENTS with default template)
  - `ai-sandbox agents clear` (remove global custom AGENTS/override so default re-seeds)
- Inside this sandbox terminal, `ai-sandbox` is available as a command alias to
  `/workspace/ai-sandbox/ai-sandbox`, so the AI can run `ai-sandbox agents reset|clear`
  directly from within the sandbox.
- Project-local `AGENTS.md` and the shared global `AGENTS.md` are different
  layers; do not confuse them when applying instruction changes.

## Root-cause policy (upstream first)
- Always trace bugs or change requests to the highest upstream source in the codebase and fix it there first.
- Do not patch symptoms at lower layers when the true source can be fixed upstream.
- Treat local workarounds as last resort only: if unavoidable, explain why upstream resolution is not feasible and document residual risk.
- Before adding a fix, inspect call flow and ownership boundaries to avoid solving the same problem multiple times in different layers.

## Coding principles
- Use functional style where practical: avoid hidden side effects, avoid global state, pass dependencies as function arguments, and prefer composition over inheritance.
- Code should be easy to understand, not fancy. Explicit is better than implicit.
- Keep functions focused: one function, one purpose.
- Target function size around 40 lines max. If longer is needed, split by responsibility or explain why.
- Avoid duplicate logic; keep a single source of truth.
- Never write redundant code. Before adding new code, check whether equivalent logic already exists.
- If the same behavior is needed in multiple places, extract it into a reusable function with explicit parameters instead of duplicating it.
- Even when logic is only sufficiently similar (not identical), prefer abstraction over copy/paste: generalize it into a reusable function or break it into smaller composable functions with explicit inputs.
- Be critical when appropriate: if a request is risky or unclear, say so and suggest a safer approach.

## bash commands for user

- we are in a sandbox here, so the user can not copy long, single-line cli commands
  without linebreaks.  You need to explicitly add line breaks and '\' and make sure,
  a command never exceeds 50 chars width. Number of lines doesn't matter...
- inside this ai-sandbox image, `apt`, `apt-get`, and `dpkg` are allowed via passwordless
  sudo wrapper. If system packages are missing, you may install them directly from inside
  the sandbox terminal.

## Scope and minimalism
- Stay minimal: implement only what was requested.
- Do not add extra CSS or UI changes unless requested.
- If additional improvements seem useful but optional, ask first.

## Quality checks
- Search the project for relevant checks and run lightweight ones after changes.
- Preferred checks: compile/type-check, linter, targeted tests, and formatter checks if configured.
- Do not run large/slow test suites unless explicitly requested.
- Never weaken tests to make them pass; fix the root cause instead.

## Visual and UI changes
- Check existing color schemes and current app style before changing visuals.
- Do not introduce random styling; follow the established design language.

## Communication expectations
- When answering questions, provide reasons, not just conclusions.
- When proposing plans or function changes, be concise and specific.
- When useful, include the proposed function signature.

## Framework-specific guidance
- Prefer explicit control flow over implicit behavior.
- For Vue, avoid overusing watchers; prefer explicit updates via functions where possible.
