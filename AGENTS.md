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
  path -- it only exists inside this container.
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
  - Codex reads: `~/.codex/AGENTS.md`
  - opencode.ai reads: `~/.config/opencode/AGENTS.md`
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

## Test-first and evidence-first development

- When a change requires tests, write or update the failing/targeted test first,
  before implementation, so the expected behavior is explicit and not biased by
  the solution already being written.
- Do not assume how existing code works. Read the relevant files, call flow,
  logs, generated output, or runtime behavior before deciding what to change.
- Let evidence from tests, diagnostics, logs, and actual code paths drive the
  implementation. If the evidence contradicts the initial assumption, revise the
  plan instead of forcing the code toward the assumption.
- Keep tests focused on the requested behavior or regression. Avoid broad test
  rewrites unless the existing test boundary cannot express the behavior.

## Critical evaluation

- Be meaningfully critical of requests instead of defaulting to agreement.
- Actively look for weak assumptions, hidden complexity, missing constraints,
  simpler alternatives, and likely failure modes.
- Push back clearly when an idea seems overcomplicated, underspecified, risky,
  or inconsistent with the existing codebase.
- When a request is risky or unclear, say so and suggest a safer approach.
- When discussing architecture, plans, or product direction, separate agreement
  from evaluation: state what is good, what is questionable, what could break,
  and what alternative you would choose.
- Give concrete reasons, not vague approval.

## Coding principles

- **Functional programming first**: no side effects, no global state, no mutation.
  Pass all dependencies as function arguments. Prefer currying when it improves
  composability and reuse. Prefer composition over inheritance.
- Prefer stateless functions wherever possible. Keep workflow state explicit in
  task data, persisted artifacts, or caller-provided arguments instead of hidden
  tool-local state, so interrupted Taskyon workflows can be resumed and audited.
- Code should be easy to understand, not fancy. Explicit is better than implicit.
- Keep functions focused: one function, one purpose.
- Target function size around 40 lines max. If longer is needed, split by responsibility or explain why.
- Avoid duplicate logic; keep a single source of truth.
- Never write redundant code. Before adding new code, check whether equivalent
  logic, helper functions, or type shapes already exist.
- Do not create parallel helper implementations, local test copies, compatibility
  wrappers, or one-off type aliases for the same concept. Put the behavior or
  type in the owning source module once, then import or inject that single owner.
- Tests, diagnostics, and temporary scaffolding must also use the same source of
  truth; do not duplicate production helpers inside tests just to avoid an
  import.
- If the same behavior is needed in multiple places, extract it into a reusable function with explicit parameters instead of duplicating it.
- Even when logic is only sufficiently similar (not identical), prefer abstraction over copy/paste: generalize it into a reusable function or break it into smaller composable functions with explicit inputs.
- Prefer functional style and composition, but keep the code readable. Avoid
  unnecessary nesting, clever abstractions, and indirection that makes the
  control flow harder to follow.
- Extract helpers when they remove real duplication or clarify a distinct step.
  Do not extract helpers only to make code look abstract.
- Do not add named one-line pass-through functions only to adapt arguments,
  capture module variables, or rename another function call, such as
  `async function loadThing() { return await loadThingFromSource(source) }`.
  Keep that dependency visible as an explicit argument, for example
  `createThingLoader(source)`, instead of hiding module state in a deferred
  callback. Add a named helper only when it contains meaningful logic, is
  reused, or makes a non-trivial domain step clearer.
- Do not add default factories or convenience wrappers that only bind one
  dependency, forward arguments, rename another function, or hide an import.
  Compose the real function directly at the call site with explicit
  dependencies. For example, call
  `createPgLiteTaskManagerStorageService(port, getDatabase)` instead of adding
  `createDefaultTaskManagerStorageService(port)`.
- Avoid unnecessary nesting and factory layers. If an object, function, or
  module exists only to return another object/function without owning
  meaningful logic, remove it and keep the flow flat and explicit.
- Do not wrap a single argument in an options, setup, or configuration object
  merely to anticipate possible future parameters. Pass the value directly.
  Introduce a wrapper object later only when multiple related values actually
  need to travel together or the object has meaningful domain semantics.
- Avoid hidden module-level dependencies in helpers and callbacks. If a
  function depends on a value from the surrounding module, pass that value as an
  explicit argument to the helper or loader constructor instead of capturing it
  implicitly.
- Do not add function wrappers, factory layers, or delegated "run" functions
  unless they are used by more than one caller or remove real complexity. Keep
  a tool's schema, parameters, and execution function together at the
  `createTool` boundary when there is no reusable abstraction.
- Prefer one large, explicit tool object declaration over scattering a tool's
  name, schema, parameters, render options, and execution body across nearby
  helper constants. This makes it easier to see what the tool actually does.

## TypeScript readability

- Optimize TypeScript for local readability first, then reuse. Strong types are
  required, but do not split every tiny local concept into top-level aliases just
  to make the type graph look tidy.
- Let TypeScript infer local variable types, callback parameters, and
  implementation return types when the result is obvious from nearby code.
  Add explicit annotations at public boundaries, where inference becomes broad
  or unclear, or where an annotation documents an important contract.
- Use separate named types when the name carries domain meaning, the type is
  reused, it is a public API boundary, or it is complex enough that naming makes
  the code easier to read.
- Prefer inline unions or a single nearby options type for small local details.
  Avoid extra aliases such as one-off mode unions, one-off legacy arg wrappers,
  or types that merely mirror part of another type without adding meaning.
- At function boundaries, write short and moderate object shapes inline so
  callers and reviewers can see the expected data locally. Do not hide a
  one-use, easily readable shape behind a type alias. Use a named type when it
  is reused, public, carries important domain meaning, or is genuinely too
  large to read comfortably inline.
- Do not add explicit parameter or return annotations that merely repeat what
  TypeScript already infers, and do not introduce exported implementation types
  solely to annotate one local function.
- Keep types close to the code that uses them. Do not create a broad shared
  "normalized type universe" for implementation details.
- For APIs with multiple strategies, prefer an explicit required `mode` or
  `method` field when callers must choose behavior, and implement the branch with
  a simple `switch` statement.
- Do not merge unrelated controls into one parameter. For example, a traversal
  limit such as `maxFollow` should stay separate from an options object that
  selects the traversal strategy.

## Bash commands for user

- Prefer CLI examples that are easy to copy safely.
- Format every shell command intended for the user to copy at no more than 50
  characters per line. Use explicit `\` line continuations when a command needs
  multiple lines; the number of lines does not matter.
- Inside this ai-sandbox image, `apt`, `apt-get`, and `dpkg` are allowed via passwordless
  sudo wrapper. If system packages are missing, you may install them directly from inside
  the sandbox terminal.

## Scope and minimalism

- Stay minimal: implement only what was requested.
- Do not add extra CSS or UI changes unless requested.
- If additional improvements seem useful but optional, ask first.
- Do not unstage files from Git unless the user explicitly asks. The user may
  use the index to track small incremental AI changes, so commands like
  `git restore --staged`, `git reset`, or equivalent index cleanup can destroy
  useful review state.
- When resolving conflicts or merging changes, trace the relevant upstream
  changes first. If there is even slight doubt about the correct resolution,
  ask the user before choosing.

## Quality checks

- Search the project for relevant checks and run lightweight ones after changes.
- Preferred checks: compile/type-check, linter, targeted tests, and formatter checks if configured.
- Do not run large/slow test suites unless explicitly requested.
- Never weaken tests to make them pass; fix the root cause instead.

## Reviewable Git staging

- When the user asks to organize a dirty worktree into focused staged batches
  for them to review and commit, use the `stage-reviewable-changes` skill at
  `/sandbox-home/.codex/skills/stage-reviewable-changes/SKILL.md`.
- Stage only one coherent batch at a time and never create the commit unless
  separately requested.
- Optimize the complete branch for a small, comprehensible commit series rather
  than minimizing the size of every individual commit. Unless the user requests
  finer granularity, aim for roughly three substantial commits for a
  branch-sized feature; use fewer or more only when the major ownership
  boundaries genuinely require it.
- Prefer combining closely related contracts, implementation, integration,
  tests, and documentation into one review unit, even when that exceeds the
  usual four-or-five-file heuristic. A single-file commit is appropriate only
  when the file is independently meaningful or combining it would obscure a
  separate concern.
- Before proposing another small batch in a long sequence, reassess the
  remaining branch diff and consolidate adjacent work so the review does not
  become a tedious series of micro-commits.

## Git authorship

- Never use `Codex`, `codex@openai.com`, or another invented AI identity as a
  Git commit author or committer.
- Preserve the existing author and committer identities when rewriting history
  unless the user explicitly requests an identity change.
- When creating or rewriting a commit requires an identity and the intended
  human identity is not unambiguous from repository configuration, existing
  commits, or the user's instructions, ask the user and stop before committing.
- Supply an explicitly confirmed human identity through command-scoped Git
  configuration when the repository has no suitable configured identity; do
  not change repository or global Git identity implicitly.

## Visual and UI changes

- Check existing color schemes and current app style before changing visuals.
- Do not introduce random styling; follow the established design language.

## Communication expectations

- Prefer simple, plain English. Avoid unnecessary jargon, expert terminology,
  or overly complex language. Clear explanations beat impressive-sounding ones
  -- complex language can hide gaps in reasoning or lack of understanding.
- When answering questions, provide reasons, not just conclusions.
- When proposing plans or function changes, be concise and specific.
- When useful, include the proposed function signature.

## Framework-specific guidance

- Prefer explicit control flow over implicit behavior.
- For Vue, avoid overusing watchers; prefer explicit updates via functions where possible.
