---
name: resolve-rebase-conflicts
description: Audit and resolve a paused Git rebase by intent, including explicit unmerged paths and semantic conflicts Git merged or dropped silently. Use when a rebase has conflicts, when both branches changed related architecture or ownership, when the user wants decision points before resolution, or when resolved files should be staged while leaving rebase continuation to the user.
---

# Resolve Rebase Conflicts

Preserve the paused operation and reason from both branches' intent. Treat a clean textual merge as
insufficient evidence of semantic compatibility.

## Establish the exact repository and authorization

1. Read every applicable repository instruction and Git workflow policy.
2. Locate the Git repository that owns the rebase. Inspect nested repositories directly; do not
   infer the active operation from a parent repository's status.
3. Record without mutating:

   ```bash
   git rev-parse --show-toplevel
   git status --short --branch
   git status
   git diff --name-status --diff-filter=U
   git ls-files -u
   git show --format=fuller --stat --summary REBASE_HEAD
   git rebase --show-current-patch
   ```

4. Preserve unrelated staged, unstaged, and untracked work. Never abort, skip, amend, continue,
   commit, switch branches, or push unless the user separately authorizes that action.
5. Ask who should run `git rebase --continue` only when the user's instruction is unclear. If the
   user wants to continue it themselves, leave the repository paused after staging resolutions.

## Reconstruct both intents

For each explicit conflict, inspect all three index stages:

```bash
git show :1:path/to/file
git show :2:path/to/file
git show :3:path/to/file
git diff :1:path/to/file :2:path/to/file
git diff :1:path/to/file :3:path/to/file
git diff --cc -- path/to/file
```

Do not label stage 2 or stage 3 as “ours” or “theirs” without explaining their role in the current
rebase. Identify the new base behavior, the replayed commit behavior, and the owning source of truth.

Inspect the commits added to the new base and the complete replayed commit, not only conflict hunks.
Use ancestry and changed-path inventories to find overlap. Read callers, tests, configuration, and
newly introduced replacement modules whenever a symbol moved or an abstraction changed.

## Audit silent semantic conflicts

Review every file in the replayed patch, including paths Git staged automatically. Specifically look
for:

- a newer API or architecture being reverted by an older cleanly applied hunk;
- two sources of truth surviving under different names;
- injected host or runtime dependencies bypassed by a default singleton;
- new lifecycle operations, cleanup, flushing, or disposal being lost;
- configuration fields added on the base but omitted by a refactor;
- protocol, storage, security, or package ownership moving between modules;
- an already-upstream patch being duplicated, partially dropped, or made inconsistent;
- tests that pass textually while exercising an obsolete code path;
- renamed files, exports, and callers whose changes do not share a conflicting line.

Compare the staged automatic merge against both intent patches. Search changed symbols across the
resulting tree. A path-overlap inventory is a starting point, not the end of the audit.

## Stop at real decisions

Classify each finding:

- **Mechanical composition:** both intents can coexist with one ownership-preserving resolution.
- **Semantic decision:** preserving one behavior weakens, replaces, or changes the other, or the
  correct owner cannot be proven from current evidence.

Before editing a semantic decision, stop and ask the user. Present:

1. the replayed commit and exact files or symbols;
2. what the new base intends;
3. what the replayed commit intends;
4. the concrete consequences of each viable choice;
5. a recommendation based on ownership, chronology, tests, and branch intent.

Ask one focused decision at a time when later choices depend on it. Do not manufacture choices when
both intents compose mechanically, but disclose those planned mechanical resolutions before editing
if the repository policy requires approval.

## Apply only approved resolutions

After approval, reinspect status and index stages before editing. Resolve at the highest owning
boundary and preserve both intents where approved. Do not select an entire side merely because it is
newer.

Format only files edited during resolution with the repository's configured formatter. Stage only
the resolved paths; do not unstage existing changes. Then inspect:

```bash
git status --short
git diff --cached --check
git diff --cached HEAD -- resolved/path
git grep -n -E '^(<<<<<<< .+|=======|>>>>>>> .+)$'
```

Run focused type checks or tests for the changed boundary when authorized and proportionate. Do not
run a repository's opt-in lint or broad suite against its instructions.

## Hand off the paused rebase

When the user owns continuation, finish with all approved conflict files resolved and staged, while
leaving rebase metadata intact. Report:

- the current replayed commit and new base;
- explicit conflicts resolved;
- silent semantic conflicts found and how they were handled;
- unresolved decisions or remaining todo commits;
- checks run and checks skipped;
- the exact fact that `git rebase --continue` was not run.

Do not imply that later commits are conflict-free. Each continuation can reveal another explicit or
semantic conflict and requires a fresh audit.
