---
name: rebase-feat-branches
description: Safely sweep feature branches from a user-confirmed authoritative remote or ref namespace onto a selected base, replacing local feature tips from matching remote-tracking refs, preserving dirty worktrees, pausing in place for Git or semantic conflicts, and verifying rewritten history before any force-with-lease push. Use for repository-wide feature-branch rebases, remote-only feature inventories, divergent local feature refs, repositories with multiple remotes, or follow-up resolution of a paused rebase.
---

# Rebase Feature Branches

Keep the operation evidence-driven and reversible. Never resolve an unapproved conflict, abort a
paused rebase, or push rewritten branches implicitly.

## Establish scope and freshness

1. Read every applicable `AGENTS.md` and repository-specific workflow policy before changing refs.
2. Treat the Git repository containing the current working directory as the scope. Inspect nested repositories and submodules, but do not rewrite their branches unless the user names them separately.
3. Inspect every remote and feature namespace before mutating:

   ```bash
   git status --short --branch
   git worktree list --porcelain
   git remote -v
   git for-each-ref --sort=refname \
     --format='%(refname:short)%09%(objectname)%09%(upstream:short)%09%(worktreepath)' \
     refs/heads/dev refs/remotes refs/heads/feat
   ```

4. Show the available remote feature namespaces and ask which remote or ref namespace is
   authoritative. Never infer authority from a remote named `origin`, from local upstream settings,
   or from which remote has more branches. Obtain this answer before deleting, recreating, or
   rebasing local feature branches.
5. Run `git fetch <source-remote> --prune` when the user asks for the newest remote state. If it
   fails, report the exact authentication, network, or metadata error. Use existing remote-tracking
   refs only with an explicit freshness caveat; never call them confirmed-current.
6. Use `<source-remote>/dev` as the base unless the user explicitly chooses another ref. Record its
   full hash.

## Build the authoritative branch inventory

After the user selects the authoritative namespace, treat only `<source-remote>/feat/*` as the
source of truth for that sweep:

1. Build the selected branch set only from `refs/remotes/<source-remote>/feat/*`.
2. Confirm no local `feat/*` branch is checked out in another worktree.
3. Record every local and remote feature tip before changing refs so divergent or local-only work
   remains auditable and recoverable through reflogs.
4. Delete local `feat/*` branches only after the inventory is complete. Do not ask whether a
   divergent local tip should replace its matching authoritative remote tip; it is not authoritative.
5. Recreate local tracking branches only for matching `<source-remote>/feat/*` refs using
   `git branch --track`.
6. Leave local-only feature branches absent and do not replay their commits. Report them as excluded
   local tips rather than as blocked sweep branches.

Do not carry the selected authority into later sweeps. Ask again whenever a new sweep begins because
repository remotes and their ownership may have changed.

## Preserve the main checkout

If the main checkout is dirty or contains untracked files, create a temporary worktree at the
selected base and perform the sweep there. Do not clean, stash, stage, or alter the user's main
checkout. Use an explicit temporary path and remove it after verification.

## Replay and audit one commit at a time

For each selected local `feat/*` branch:

1. Switch to the branch in the temporary worktree.
2. Preserve the existing human author and committer identities. If Git requires an identity to
   continue and the intended identity is unambiguous, supply that human identity with command-scoped
   configuration. Never use `Codex`, `codex@openai.com`, or another invented AI identity. If the
   intended identity is unclear, stop and ask the user. For example:

   ```bash
   git -c user.name="$CONFIRMED_NAME" \
     -c user.email="$CONFIRMED_EMAIL" \
     rebase "$SELECTED_BASE"
   ```

3. Use an interactive rebase that marks every replayed commit as `edit`. This creates an audit stop
   after each commit even when Git applies it cleanly. Preserve fixup, squash, merge, and other todo
   semantics; only change ordinary `pick` commands to `edit`.
4. At each successful edit stop, inspect the complete replayed commit and its current consumers:

   ```bash
   git show --format=fuller --stat --summary HEAD
   git show --check --no-ext-diff HEAD
   git diff HEAD^ HEAD --
   ```

   Search changed symbols and paths in the rebased tree. Look for duplicated helpers, parallel
   schemas or state, obsolete adapters, ownership moves, incompatible runtime assumptions, and
   behavior already implemented differently on the base. A clean Git application is not proof of
   semantic compatibility.
5. If the commit is coherent with the current tree, continue to the next audit stop. If any
   semantic choice is uncertain, leave the rebase paused at the edit stop, report the evidence and
   recommendation, and ask the user. Do not amend, skip, or continue that commit without approval.
6. On a Git conflict, capture evidence without aborting:

   ```bash
   git status --short
   git diff --name-status --diff-filter=U
   git ls-files -u
   git show --format=fuller --stat --summary REBASE_HEAD
   git diff --cc --no-ext-diff
   ```

7. Leave the conflicted files, index stages, temporary worktree, and rebase metadata intact. Stop
   the entire sweep and ask the user before switching branches. Abort only when the user explicitly
   requests it or continuing safely becomes impossible and the user approves restoration.

Describe each Git or semantic conflict by replayed commit, exact files or symbols, current ownership
boundary, and decision severity. Distinguish mechanical adaptation from a product or ownership
choice. Do not choose a side wholesale when newer base architecture moved the source of truth.

## Resume an approved pause

After the user decides a conflict:

1. Reinspect status, the current patch, unmerged stages, and the user's exact decision before
   changing files.
2. Apply only the approved ownership decision. Format only files edited during resolution and stage
   only those conflict resolutions.
3. For a semantic edit stop, amend or skip only when the user approved that action; otherwise
   continue without changing the replayed commit.
4. Continue non-interactively with the confirmed human identity.
5. Stop again at the next per-commit audit or Git conflict. Do not infer that an earlier decision
   authorizes a later semantic choice.

## Verify and report

For every successful branch:

```bash
git merge-base --is-ancestor "$SELECTED_BASE" feat/example
git diff --check "$SELECTED_BASE"...feat/example
git grep -n -E '^(<<<<<<< .+|=======|>>>>>>> .+)$' feat/example
```

Use the exact marker expression above; looser `=======` matching produces false positives in decorative comments.

Run focused checks for any files manually resolved. Remove the temporary worktree only after the
rebase completes or the user explicitly approves an abort. Then confirm:

- the main checkout and its index are unchanged;
- no rebase state remains;
- every successful branch contains the recorded base;
- every intentionally aborted branch returned to its recorded original tip;
- all local feature branches still track the matching remote branch.

Report successful, paused, aborted, and blocked branches separately. Include base hash, current
replayed commit for paused work, new local tips, skipped checks, fetch freshness limitations, and
existing unrelated dirt left untouched.

Never push unless the user asks. When publishing rewritten history, use `--force-with-lease`, list the intended branches explicitly, and never use plain `--force`.
