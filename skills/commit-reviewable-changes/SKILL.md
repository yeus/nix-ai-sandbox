---
name: commit-reviewable-changes
description: Organize finished work into focused Git commits on one branch, continuing until no in-scope finished changes remain. Use when the user asks for autonomous staging and committing; mentioning the skill or discussing commits alone is not authorization.
---

# Commit Reviewable Changes

Organize existing changes into a short, coherent commit series and create each commit after reviewing it. Continue through clearly finished changes in the requested scope. Leave work in progress, ambiguous, unrelated, or blocked changes untouched and report them.

## Confirm the branch and scope

The user must name the one branch for this run. If they have not named it, ask which branch to use and wait before staging or committing; do not infer it from the current checkout. Identify the target repository from the request. If the intended repository is unclear, ask before mutation.

Require that the named branch is already checked out in the target repository. Check `git branch --show-current` and stop if it differs, is empty, or the checkout is detached. Ask the user to switch to the named branch. Never switch branches. Recheck the branch before every commit and stop if it changes. Do not commit in another repository or submodule during this run; treat its work as a separate request. A parent repository's gitlink change can be considered as a parent-repository change when its purpose is clear.

## Inspect the repository state

Read applicable `AGENTS.md` files and repository-specific commit or validation instructions. Inspect the target repository's state, including:

```bash
git status --short --branch
git diff --name-status
git diff --cached --name-status
git submodule status
```

Read the full relevant diffs. Inspect untracked files before including them. Establish which changes belong to the user's requested scope; preserve unrelated and pre-existing changes. Never stage secrets, personal data, logs, generated diagnostics, build output, caches, or unexplained artifacts.

Inspect any pre-existing staged diff as carefully as unstaged changes. Commit it only if the entire staged batch is clearly in scope, finished, safe, and independently reviewable. If it is mixed, ambiguous, or unrelated, do not alter the index or stage more work; stop and explain what needs review. Never unstage or reset existing index state.

## Decide what is finished

A change is eligible when it clearly supports the requested outcome, forms a complete and understandable behavior or documentation change, has no explicit work-in-progress signal, and passes the checks relevant to it. Use the task description, repository state, implementation and its focused verification as evidence; do not infer completion solely from a clean diff or passing tests.

Do not commit partial work that depends on unfinished changes to make sense. If one batch is blocked or fails a relevant check, leave it uncommitted; continue only with other independent finished batches. If status is ambiguous, leave that work untouched and report the uncertainty. This skill organizes and commits existing work; do not invent unrelated implementation changes to make a batch commit-ready.

## Plan a short commit series

Inventory the full in-scope diff before choosing a batch. Plan a small series, usually about three substantial commits for branch-sized work, ordered by dependency and ownership. Combine related implementation, focused tests, integration, and necessary documentation. Keep unrelated concerns separate; do not create a chain of micro-commits. Reassess the remaining diff after every commit and consolidate adjacent work when that makes the series easier to review.

## Stage and verify one batch at a time

Select one complete review unit. Stage only explicit paths or carefully selected hunks. Never use `git add .`, `git add -A`, a broad directory, or an unresolved glob. Avoid staging a whole file when it contains unrelated changes. Do not edit the worktree to manufacture a staging boundary.

Before committing, inspect exactly what is staged:

```bash
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
git diff --cached
```

Confirm that the staged diff is coherent on its own, belongs to the requested scope, includes required focused tests or contract updates, and contains no unrelated or sensitive content. Run lightweight checks that apply to this batch and follow repository instructions. Do not claim checks that were not run. If the index contains anything beyond the reviewed batch, do not commit it; stop rather than removing or resetting staged work.

## Commit and continue

Use the repository's commit-message style. Prefer an imperative, specific title and a short body explaining the behavior and reason when useful. Check the configured Git author and committer identity. Preserve a suitable existing human identity; never invent an AI identity. If no suitable identity is configured or unambiguous from repository history or the user's instructions, stop and ask.

Immediately before each commit, verify the named branch is still checked out and review the complete staged diff once more. Create one commit for the verified batch. Let commit hooks run normally; if a hook fails, stop and report it without bypassing the hook. Never push, amend, rebase, stash, discard, reset, or switch branches as part of this skill.

After each successful commit, verify the branch and inspect `git status --short --branch` and the new commit with `git show --stat --oneline HEAD`. Check whether hooks or other processes changed the worktree. Then reassess the remaining in-scope changes, plan the next substantial batch, and repeat. Stop when all clearly finished in-scope changes are committed, or when remaining work is ambiguous, unfinished, unsafe, or blocked.

## Report the result

Summarize the commits created with their hashes and subjects, the checks run, and any remaining uncommitted work with the reason it was left. State the repository and branch used. Do not imply that unrelated or ambiguous work was committed.
