# AGENTS.md instructions for /workspace/ai-sandbox

## Priority order (highest first)
1. Correctness and requested scope
2. Simplicity and explicit flow
3. Functional style and composition
4. Lightweight quality checks

If rules conflict, follow the higher-priority rule and state the tradeoff briefly.

## Coding principles
- Use functional style where practical: avoid hidden side effects, avoid global state, pass dependencies as function arguments, and prefer composition over inheritance.
- Code should be easy to understand, not fancy. Explicit is better than implicit.
- Keep functions focused: one function, one purpose.
- Target function size around 40 lines max. If longer is needed, split by responsibility or explain why.
- Avoid duplicate logic; keep a single source of truth.
- Be critical when appropriate: if a request is risky or unclear, say so and suggest a safer approach.

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
