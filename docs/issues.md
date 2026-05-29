# Workspace Issues

Known friction points encountered while working inside this sandbox. These are not feature requests; they are operational issues that can slow down future agents or cause confusing failed tool calls.

---

## Tool sandbox namespace failures for simple commands

**Observed:** Several otherwise harmless commands failed with:

```text
bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.
```

This affected commands such as `whoami`, `git status --short`, and some `sed` reads when run through the default tool sandbox.

**Impact:** Basic inspection commands may fail even though the underlying command is valid. The failure is noisy and can look like a repo problem when it is actually an execution-environment issue.

**Workaround used:** Re-run the same command with escalated sandbox permissions. For example, `whoami` succeeded and returned `agent` when run outside the failing helper.

**Follow-up:** Investigate whether the Codex tool sandbox should detect this host/kernel state and either avoid `bwrap` automatically or provide a clearer local diagnostic. If this is expected inside the devcontainer, document the preferred escalation pattern in `CLAUDE.md`.

---

## `apply_patch` can fail for existing files under the same namespace issue

**Observed:** `apply_patch` succeeded when adding `docs/gpt-tasks.md`, but later failed while trying to update `docs/CHANGELOG.md`:

```text
apply_patch verification failed: Failed to read file to update ... fs sandbox helper failed ... bwrap: No permissions to create a new namespace
```

**Impact:** The preferred file-editing path can be unreliable for existing files. This is especially awkward for required changelog updates, because it can block a normal documentation workflow.

**Workaround used:** A narrow escalated shell edit was used for the changelog, followed by index-only staging so unrelated pre-existing changelog edits were not included in the commit.

**Follow-up:** Fix or bypass the filesystem sandbox helper for `apply_patch` in this environment. If that is not possible, document an approved fallback for small, targeted edits that preserves the "do not touch unrelated changes" invariant.

---

## Changelog had unrelated uncommitted edits

**Observed:** `docs/CHANGELOG.md` already contained uncommitted entries from other workspace changes. Adding a new changelog entry produced one combined diff hunk with unrelated entries.

**Impact:** `git add -p` could not easily stage only the new entry because all top-of-file additions were collapsed into one hunk. This made it easier to accidentally commit unrelated work.

**Workaround used:** Build an index-only version of `docs/CHANGELOG.md` from `HEAD`, add only the new entry to that temporary version, write it as a blob, and update the index with `git update-index --cacheinfo`.

**Follow-up:** Prefer committing changelog entries together with their originating changes before starting new work. Consider keeping pending issue/task notes in a separate file until they are ready to commit, then add the changelog entry in the same clean commit.

---

## Worktree contains unrelated dirty and untracked files

**Observed:** The workspace had multiple modified and untracked files unrelated to the GPT task work:

```text
.devcontainer/devcontainer.json
.devcontainer/devcontainer.template.json
CLAUDE.md
docs/CHANGELOG.md
docs/SKILLS_LINKING.md
test/test_devcontainer.sh
.DS_Store
docs/.DS_Store
docs/architecture-refactor.md
setup/
skills/
```

**Impact:** Every commit requires extra care to avoid staging unrelated files. It also makes `git status` harder to use as a quick signal of what changed during the current task.

**Workaround used:** Stage exact files and verify the staged diff with `git diff --cached --stat` and targeted `git diff --cached -- <file>` before committing.

**Follow-up:** Clean up or commit the existing worktree changes when appropriate. Add `.DS_Store` entries to `.gitignore` if they are not intentionally tracked.
