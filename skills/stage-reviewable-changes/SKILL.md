---
name: stage-reviewable-changes
description: Stage an existing dirty Git worktree as a short, squash-friendly sequence of substantial, coherent, human-reviewable batches without committing. Use when the user wants a branch organized into a few focused proposed commits, explicit staging for review, related changes kept together, and detailed commit messages for commits they will create themselves.
---

# Stage Reviewable Changes

Stage exactly one substantial coherent batch, verify it, propose its commit message, and stop for
human review. Never commit, push, stash, discard, or rewrite changes.

## Establish the repository boundary

1. Read applicable `AGENTS.md` files and repository workflow policies.
2. Resolve the repository containing the requested changes. Inspect nested repositories and
   submodules; never mistake a submodule gitlink change for its internal file changes.
3. Inspect branch, worktree, and index state separately:

   ```bash
   git status --short --branch
   git diff --name-status
   git diff --cached --name-status
   git submodule status
   ```

4. If the index already contains a batch awaiting review, do not add another batch. Describe the
   staged state and wait for the user to commit or explicitly revise it.
5. Preserve all unrelated and pre-existing changes. Inspect untracked files before considering
   them; do not stage secrets, logs, build products, caches, or unexplained artifacts.

## Plan the commit series

Before selecting the first batch, inventory the dirty worktree broadly enough to outline the
complete branch-level series and its dependency order. Unless the user requests finer granularity,
target roughly three substantial commits for a branch-sized feature. Use fewer or more only when
genuinely separate concerns make that clearer.

- Treat the total commit count as a design constraint. Do not optimize each batch in isolation and
  accidentally produce a long sequence of micro-commits.
- Finish one feature or ownership cluster before switching to an unrelated cluster.
- Use consistent commit-message scopes and terminology throughout one cluster.
- Combine closely related contracts, implementation, integration, tests, fixtures, and
  documentation when they deliver one reviewable behavior.
- Split layers into separate commits only when each layer is independently useful, independently
  verifiable, or materially easier to review on its own.
- Keep every batch independently understandable and reviewable even when several adjacent batches
  are likely squash candidates.
- Avoid interleaving drive-by cleanup, unrelated documentation, or another feature between related
  batches.
- Queue newly discovered unrelated work for a later cluster rather than disturbing the current
  sequence.

Prefer a short series whose adjacent commits tell one continuous story and whose squashed diff
forms one coherent change without fixup churn or contradictory intermediate decisions. After each
handoff, reassess the remaining branch diff and consolidate the next batch if the series is becoming
repetitive or tedious.

## Choose one review unit

Inspect the full relevant diffs and group changes by one substantial behavior or feature boundary.
Keep an implementation with its focused tests, schemas, fixtures, integration, and directly
necessary documentation. File count is secondary to completeness and branch-level reviewability:

- freely use more than four or five files when they implement one coherent behavior;
- use a single-file batch only when it is independently meaningful or combining it would obscure a
  separate concern;
- avoid repeated single-file batches in the same cluster;
- never combine unrelated work merely to reach the target count;
- defer downstream changes until their upstream contract can be reviewed first;
- avoid staging a whole file when it contains unrelated changes.

If a mixed file prevents a clean whole-file batch, prefer another complete batch. Use partial hunk
staging only after inspecting every selected hunk and confirming the cached result is independently
coherent. Never modify the worktree merely to manufacture a staging boundary.

## Stage explicitly

Stage only enumerated paths or deliberately selected hunks. Never use `git add .`, `git add -A`, a
broad directory, or an unresolved glob.

For a whole-file batch:

```bash
git add -- path/to/file-a path/to/file-b
```

Record which paths were introduced into the index during this turn so an accidental selection can
be removed without disturbing pre-existing staged work.

## Verify the proposed commit

After staging, inspect the index as the reviewer will see it:

```bash
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
git diff --cached
```

Confirm that:

- every staged change supports the stated topic;
- required tests or contract updates are included;
- no unrelated hunks, generated artifacts, debug output, or secrets are present;
- the cached diff is understandable without relying on unstaged follow-up work.

Run only lightweight checks that are useful for this batch. Do not change implementation merely to
make the grouping convenient.

## Propose the commit message

Follow the repository's observed commit-message style. Provide approximately four or five physical
lines: a concise imperative title, a blank line, and two or three concrete body lines describing
the behavior and important architectural reason.

Example:

```text
feat(design): add Git-backed repository proposal

Separate semantic node identity from Git object storage.
Define the shared OPFS repository and synchronization boundary.
Document migration constraints and adoption checks.
```

Do not claim checks, behavior, or files that are not in the cached diff.

## Hand off and stop

Report:

- the staged paths;
- why they form one review unit;
- the current topic cluster and this batch's position in the short planned branch-level series;
- the proposed commit message in a copyable code block;
- checks run and any limitations;
- a short preview of the next adjacent batch and remaining topic clusters, without staging them.

Explicitly state that no commit was created. Wait for the user to review and commit. On the next
invocation, re-inspect the index rather than assuming the proposed commit was made.
