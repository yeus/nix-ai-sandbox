---
name: squash-reviewable-branch
description: Consolidate a clean Git feature branch into a user-selected number of thematic commits with interactive rebase while preserving the exact final tree and every original commit message. Use when a user asks to squash, condense, tidy, or reduce branch history, including when they provide an explicit interactive-rebase base and branch.
---

# Squash Reviewable Branch

Consolidate one feature branch reversibly. Preserve its content and original commit messages; do
not push rewritten history implicitly.

## Establish the boundary

1. Read applicable repository instructions and Git workflow policies.
2. Inspect the worktree, index, branch, upstream, worktrees, submodules, and rebase state.
3. Require a clean worktree and index. Do not stash, discard, or absorb unrelated files.
4. Identify the exact commits owned by the branch. Distinguish these operations explicitly:
   - **Squash only:** use the existing branch point or merge base.
   - **Update onto another base:** use the user-selected base and treat conflicts separately.
5. If the user supplies an explicit base and branch, verify that the base is an ancestor and use
   those exact refs. Do not silently substitute a newer base or a computed merge base.
6. Inspect merge commits in the range. Stop and explain before flattening merges, subtree imports,
   or other history whose topology carries meaning.
7. Record the original tip and tree hash. Create a clearly named local backup branch before
   rewriting anything.

## Plan a short thematic history

Inventory every full commit message and its affected files. Group commits by behavior or ownership
boundary, not merely by size. Account for every original commit exactly once before rewriting.

Optimize the resulting history for future rebases as well as human review. Within one behavior or
ownership boundary, prefer a single commit when several commits repeatedly edit the same files.
Fold small dependent edits into their topic commit, and always squash a corrective follow-up into
the earlier commit whose behavior it fixes unless preserving the correction separately carries
meaningful historical value. Do not preserve implementation-then-repair churn that would force a
future rebase to resolve the same area repeatedly.

Use file overlap as supporting evidence, not as the sole grouping rule. Shared files may still
contain unrelated ownership changes, while a coherent topic can span different files. Prefer the
smallest number of commits that preserves real semantic boundaries and dependency order.

Keep groups contiguous when practical. Move a non-contiguous commit only after checking its file
overlap and dependency order against every commit it crosses. Do not reorder merely to make the
group subjects look cleaner.

Target the user's requested count. If no count is given, prefer three to five substantial commits.
If the requested count would force unrelated ownership boundaries together, explain the concrete
grouping problem and ask before choosing a different count.

## Execute the interactive squash

1. Create a temporary sequence editor that writes the reviewed todo. Parameterize the base,
   branch, commit hashes, actions, and group count from the inspected repository; do not embed
   example-specific refs in the skill.
2. Include every original commit exactly once. Use one `pick` followed by `squash` entries for each
   group; use no other todo actions unless the user explicitly requests them.
3. Run the user-selected form of the command:

   ```bash
   GIT_SEQUENCE_EDITOR=<sequence-editor> \
   GIT_EDITOR=true \
   git rebase -i <base> <branch>
   ```

   Supply the confirmed human identity with command-scoped Git configuration if the repository
   does not already provide it.

## Preserve standard Git squash messages

These are hard requirements unless the user explicitly asks for rewritten messages:

- Use `squash`, not `fixup`.
- Do not run `git commit --amend` to replace the combined message.
- Do not introduce a new summary subject or body.
- Leave Git's generated combined-message buffer unchanged.
- Retain the first picked commit's message followed by every squashed commit's original message in
  their group order.

When automating a non-interactive run, a no-op commit-message editor may accept Git's generated
buffer unchanged. The sequence editor may only arrange commits and change actions to `pick` or
`squash`; it must not author commit messages.

Standard squash output can contain awkward, duplicated, or outdated wording. Preserve it anyway.
Only clean it up after the user separately authorizes message rewriting.

## Handle conflicts conservatively

On the first conflict, capture the replayed commit, unmerged files, index stages, and combined diff.
Abort the rebase rather than choosing a semantic resolution without approval. Confirm the backup
still points to the original tip.

## Verify the rewrite

After success, verify all of the following:

1. The branch contains the requested number of commits.
2. The new tip tree hash equals the backup tip tree hash.
3. `git diff --exit-code <backup>..HEAD` is empty.
4. Every final commit message equals the ordered concatenation of the original `%B` messages in
   its group. Compare the actual full texts or byte streams; checking subjects alone is
   insufficient.
5. The range passes `git diff --check` and contains no conflict markers.
6. The worktree and index are clean and no rebase state remains.

Remove only temporary sequence-editor artifacts created by the workflow. Keep the backup branch
until the user explicitly asks to remove it.

## Report and stop

Report the new commit list, backup ref, base used, exact-tree result, message-retention result, and
expected upstream divergence. Do not push. If the user later publishes the rewritten branch, use
`--force-with-lease`, never plain `--force`.
