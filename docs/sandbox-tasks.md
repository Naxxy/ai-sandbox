# Sandbox Tasks

Implementation tasks for the sandbox-workspace. Each task is self-contained: a fresh Claude Code instance with access to this file and the codebase can execute it without prior context from earlier conversations.

For background on decisions, read the relevant context document before starting a task. Context documents are in `docs/` alongside this file.

---

## TASK: Implement cross-workspace skill sharing via XDG symlinks

**Context document:** `docs/SKILLS_LINKING.md` — read this first. It records the full problem statement, all alternatives that were considered and rejected, the path arithmetic that makes relative symlinks work, and known constraints and limitations. This task document covers only the how; SKILLS_LINKING.md covers the why.

**Scope:** Changes span two kinds of repos — the ai-sandbox tool repo (this repo), and each workspace repo that adopts the pattern. Steps are labelled to make clear which repo each change belongs to.

---

### Use case summary

Claude Code skills (prompt files in `.claude/skills/`) are shared across multiple workspaces. Three environments must all work: Mac terminal (via `ai-sandbox` CLI), Pi terminal (via SSH + CLI), and VS Code devcontainer. Skills must be accessible in all three without per-session sync steps or per-machine shell configuration.

The solution: skills live at `~/.local/share/ai-agents/skills/<skill-name>/` on every machine (one git clone per skill per machine). Workspaces reference skills via relative symlinks. The workspace is mounted at a depth-matched path inside the container (`/home/agent/projects/ai/<workspace-name>/`) so the relative path resolves identically on host and inside container.

---

### Prerequisites

Before starting, verify:

- [ ] `~/.local/share/ai-agents/skills/` exists on every machine that will use skills (Mac, Pi). If not, create it: `mkdir -p ~/.local/share/ai-agents/skills/`
- [ ] Each skill repo is cloned into that directory: `git clone <skill-repo-url> ~/.local/share/ai-agents/skills/<skill-name>`
- [ ] All workspaces that will adopt this pattern are at `~/projects/ai/<workspace-name>/`. If any workspace is at a different depth, the relative symlinks will not resolve — see SKILLS_LINKING.md §"Known constraints" before proceeding.
- [ ] The `ai-sandbox` CLI is installed and `ai-sandbox --version` works.
- [ ] Docker is running and `ai-sandbox:latest` image exists (`docker images ai-sandbox:latest`).

---

### End state

When this task is complete, for each workspace:

```
~/projects/ai/<workspace-name>/
  .claude/
    skills/
      <skill-name>     ← symlink: ../../../../.local/share/ai-agents/skills/<skill-name>
  .devcontainer/
    devcontainer.json  ← workspaceMount targets /home/agent/projects/ai/<name>/
                          XDG data bind mount included
  .ai-sandbox/
    sandbox.json       ← workspacePath: /home/agent/projects/ai/<name>/
                          extraMounts includes ~/.local/share/ai-agents
```

Inside the container (both CLI and devcontainer):

```
/home/agent/projects/ai/<workspace-name>/.claude/skills/<skill-name>
  → resolves to → /home/agent/.local/share/ai-agents/skills/<skill-name>
```

---

### Step 1 — Machine setup (one-time, per machine, not a git commit)

On every machine (Mac, Pi, and the devcontainer build host):

```bash
mkdir -p ~/.local/share/ai-agents/skills
```

Clone each skill repo:

```bash
git clone <url-for-adr-skill>         ~/.local/share/ai-agents/skills/adr-skill
git clone <url-for-humanizer>          ~/.local/share/ai-agents/skills/humanizer
git clone <url-for-workflow-builder>   ~/.local/share/ai-agents/skills/workflow-builder
```

**Verification:**

```bash
ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  humanizer  workflow-builder  (or whichever skills apply)

ls ~/.local/share/ai-agents/skills/adr-skill/
# Expected: the skill's contents (e.g. adr-skill.md, adr-skill/)
```

This step is not committed — it is a machine-level setup that must be done once on each machine by whoever sets up a new development environment.

---

### Step 2 — Create symlinks in the workspace repo

**In the workspace repo** (e.g. `~/projects/ai/adr-workspace/`).

Create the skills directory if it does not exist:

```bash
mkdir -p .claude/skills
```

Create a relative symlink for each skill. The relative path must be exactly `../../../../.local/share/ai-agents/skills/<skill-name>` — four levels up from `.claude/skills/` reaches `~/`, then descends into `.local/share/ai-agents/skills/`.

```bash
cd .claude/skills
ln -s ../../../../.local/share/ai-agents/skills/adr-skill adr-skill
ln -s ../../../../.local/share/ai-agents/skills/humanizer humanizer
# repeat for each skill
```

**Verification:**

```bash
ls -la .claude/skills/
# Expected: each entry shows "-> ../../../../.local/share/ai-agents/skills/<skill-name>"

file .claude/skills/adr-skill
# Expected: .claude/skills/adr-skill: symbolic link to ../../../../.local/share/ai-agents/skills/adr-skill

ls .claude/skills/adr-skill/
# Expected: skill contents — not an error

git status .claude/skills/
# Expected: untracked files (the new symlinks) — no "modified" entries, no submodule state
```

Verify what git will actually store for the symlink:

```bash
git add .claude/skills/adr-skill
git show :".claude/skills/adr-skill"
# Expected: ../../../../.local/share/ai-agents/skills/adr-skill
# (the literal relative path string, not a resolved absolute path)
```

If the output is an absolute path, the symlink was created while the target existed on macOS and got canonicalised. Remove the symlink, ensure the target directory does not yet exist, re-create with `ln -s`, then re-add.

**Commit (workspace repo):**

```
git add .claude/skills/
git commit -m "$(cat <<'EOF'
Link skills via XDG-compliant relative symlinks

Skills are no longer carried as submodules or local copies. Each skill
is a relative symlink to ~/.local/share/ai-agents/skills/<name>, which
resolves identically on Mac, Pi, and in devcontainer (workspace mounted
at /home/agent/projects/ai/<name>/). See docs/SKILLS_LINKING.md.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

**Changelog entry (workspace repo's CHANGELOG.md):**

```markdown
## Link skills via XDG symlinks *(YYYY-MM-DD)*

Replaced submodule-based skill references with relative symlinks into
`~/.local/share/ai-agents/skills/`. One git clone per skill per machine;
all workspaces share it immediately via symlinks. See
`docs/SKILLS_LINKING.md` for the full rationale and path arithmetic.
```

---

### Step 3 — Update devcontainer.json (workspace repo)

The devcontainer must mount the workspace at a path matching the host depth, and bind-mount the XDG skills directory.

**File:** `.devcontainer/devcontainer.json` in the workspace repo.

Change `workspaceMount` and `workspaceFolder`:

```json
"workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
"workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
```

Add the XDG data bind mount to the `mounts` array (alongside any existing mounts for `.claude`, `.codex`, etc.):

```json
"source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
```

**Verification (before committing):**

Open the workspace in VS Code (or rebuild the devcontainer) and verify:

```bash
# Inside the devcontainer terminal:
pwd
# Expected: /home/agent/projects/ai/<workspace-name>

ls ~/.local/share/ai-agents/skills/
# Expected: skill directories are visible

ls .claude/skills/
# Expected: skill symlinks resolve — shows skill contents, not errors

ls -la .claude/skills/adr-skill
# Expected: symlink resolving to ../../../../.local/share/ai-agents/skills/adr-skill
# which resolves to /home/agent/.local/share/ai-agents/skills/adr-skill

readlink -f .claude/skills/adr-skill
# Expected: /home/agent/.local/share/ai-agents/skills/adr-skill
```

**Commit (workspace repo):**

```
git add .devcontainer/devcontainer.json
git commit -m "$(cat <<'EOF'
Update devcontainer: depth-matched workspace mount and XDG skills bind

Mount workspace at /home/agent/projects/ai/<name>/ (not /workspace) to
preserve the four-level relative depth that symlinks in .claude/skills/
require. Bind-mount ~/.local/share/ai-agents into the container so
symlinks resolve to the shared skills directory. See SKILLS_LINKING.md.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

**Changelog entry (workspace repo):**

```markdown
## Update devcontainer for skills symlink support *(YYYY-MM-DD)*

Changed `workspaceMount` target from `/workspace` to
`/home/agent/projects/ai/<name>/` and added a bind mount for
`~/.local/share/ai-agents`. Skills symlinks now resolve correctly
inside the devcontainer.
```

---

### Step 4 — Update sandbox.json for CLI compatibility (workspace repo)

When running via the `ai-sandbox` CLI on Mac or Pi, the same workspace path must be used.

**File:** `.ai-sandbox/sandbox.json` in the workspace repo.

Set `workspacePath`:

```json
"sandbox": {
  "workspacePath": "/home/agent/projects/ai/<workspace-name>",
  ...
}
```

Add the XDG data mount to `extraMounts`:

```json
"sandbox": {
  "extraMounts": [
    { "host": "~/.local/share/ai-agents", "container": "/home/agent/.local/share/ai-agents", "readonly": false }
  ]
}
```

Note: `~` in the `host` field is expanded at runtime by the CLI — this already works in the current implementation.

**Verification:**

```bash
cd ~/projects/ai/<workspace-name>
ai-sandbox --dry-run 2>/dev/null
```

Expected output includes both of these volume flags:

```
-v /Users/guglielmino.ashar/projects/ai/<workspace-name>:/home/agent/projects/ai/<workspace-name>:rw
-v /Users/guglielmino.ashar/.local/share/ai-agents:/home/agent/.local/share/ai-agents:rw
```

Run a live container check:

```bash
ai-sandbox bash -- bash -c "readlink -f .claude/skills/adr-skill"
# Expected: /home/agent/.local/share/ai-agents/skills/adr-skill
```

**Commit (workspace repo):**

```
git add .ai-sandbox/sandbox.json
git commit -m "$(cat <<'EOF'
Update sandbox.json: depth-matched workspacePath and XDG skills mount

Sets workspacePath to /home/agent/projects/ai/<name>/ so CLI containers
mirror the host workspace depth, and adds extraMount for
~/.local/share/ai-agents so skill symlinks resolve. See SKILLS_LINKING.md.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

**Changelog entry (workspace repo):**

```markdown
## Update sandbox.json for skills symlink support *(YYYY-MM-DD)*

Set `sandbox.workspacePath` to `/home/agent/projects/ai/<name>/` and
added `~/.local/share/ai-agents` to `extraMounts`. CLI containers now
mount the workspace and skills directory at matching depths.
```

---

### Step 5 — Remove any previous submodule references (workspace repo)

If the workspace previously used git submodules for skills, remove them before or after Step 2 (not in the same commit as creating the symlinks).

```bash
# For each old skill submodule:
git submodule deinit .claude/skills/<skill-name>
git rm .claude/skills/<skill-name>
rm -rf .git/modules/.claude/skills/<skill-name>
```

Remove the `.gitmodules` file if no submodules remain:

```bash
git rm .gitmodules   # only if the file exists and is now empty
```

**Verification:**

```bash
git submodule status
# Expected: empty output (no submodules)

cat .gitmodules 2>/dev/null || echo "no .gitmodules"
# Expected: no .gitmodules, or empty file
```

**Commit (workspace repo):**

```
git commit -m "$(cat <<'EOF'
Remove skill submodules (replaced by XDG symlinks)

Skills are now symlinks to ~/.local/share/ai-agents/skills/ rather than
submodule checkouts. See commit that added .claude/skills/ symlinks.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Step 6 — Add test coverage (ai-sandbox repo)

Add test cases to `test/test_cli.sh` covering:

1. **Custom `workspacePath` is reflected in the docker command.** Create a temp sandbox.json with a non-default `workspacePath` and verify `--dry-run` output contains that path.

2. **Tilde in `extraMounts.host` is expanded.** Add an extraMount with `host: "~/.local/share/ai-agents"` and verify dry-run output shows the expanded absolute path, not the literal tilde.

These tests do not require Docker to run — they use `--dry-run` mode.

Example test structure to add to `test/test_cli.sh`:

```bash
# Test: custom workspacePath appears in docker command
test_custom_workspace_path() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir "$tmpdir/.ai-sandbox"
  cat > "$tmpdir/.ai-sandbox/sandbox.json" <<'JSON'
{
  "defaultHarness": "shell",
  "defaultModel": "local-qwen",
  "harnesses": { "shell": { "command": "bash" } },
  "models": { "local-qwen": { "provider": "ollama", "model": "test:latest" } },
  "sandbox": {
    "workspacePath": "/home/agent/projects/ai/test-workspace",
    "network": false
  }
}
JSON
  local output
  output="$(cd "$tmpdir" && ai-sandbox --dry-run 2>/dev/null)"
  if echo "$output" | grep -q '/home/agent/projects/ai/test-workspace'; then
    pass "custom workspacePath used in docker command"
  else
    fail "custom workspacePath not found in: $output"
  fi
  rm -rf "$tmpdir"
}

# Test: tilde in extraMounts.host is expanded
test_extra_mounts_tilde_expansion() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir "$tmpdir/.ai-sandbox"
  cat > "$tmpdir/.ai-sandbox/sandbox.json" <<'JSON'
{
  "defaultHarness": "shell",
  "defaultModel": "local-qwen",
  "harnesses": { "shell": { "command": "bash" } },
  "models": { "local-qwen": { "provider": "ollama", "model": "test:latest" } },
  "sandbox": {
    "workspacePath": "/workspace",
    "network": false,
    "extraMounts": [
      { "host": "~/.local/share/ai-agents", "container": "/home/agent/.local/share/ai-agents", "readonly": false }
    ]
  }
}
JSON
  local output
  output="$(cd "$tmpdir" && ai-sandbox --dry-run 2>/dev/null)"
  local expected_path="${HOME}/.local/share/ai-agents"
  if echo "$output" | grep -q "$expected_path"; then
    pass "tilde in extraMounts.host expanded to $expected_path"
  else
    fail "expected $expected_path in dry-run output; got: $output"
  fi
  rm -rf "$tmpdir"
}
```

Run the full test suite to confirm no regressions:

```bash
bash test/test_cli.sh
bash test/test_devcontainer.sh
```

**Commit (ai-sandbox repo):**

```
git add test/test_cli.sh
git commit -m "$(cat <<'EOF'
Add tests: custom workspacePath and extraMounts tilde expansion

Covers two config paths needed for XDG-based skill sharing: that a
non-default sandbox.workspacePath appears correctly in the docker
command, and that a ~ prefix in extraMounts.host is expanded to the
absolute home path before passing to docker run.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

**Changelog entry (ai-sandbox repo, `docs/CHANGELOG.md`):**

```markdown
## Add tests for custom workspacePath and extraMounts tilde expansion *(YYYY-MM-DD)*

Added two dry-run test cases to `test/test_cli.sh` covering config
features required for XDG skill sharing: `sandbox.workspacePath`
propagation and tilde expansion in `extraMounts[].host`.
```

---

### Step 7 — Update documentation (ai-sandbox repo)

Update `CLAUDE.md` file map to include `docs/SKILLS_LINKING.md`:

In the file map table, add:

```markdown
| Understand how skills are shared across workspaces and environments — decisions, path arithmetic, constraints | `docs/SKILLS_LINKING.md` |
```

Update `docs/TUTORIAL.md` if it exists to mention:
- The `sandbox.workspacePath` config key
- The XDG skills setup step as a prerequisite for skill-linked workspaces

**Commit (ai-sandbox repo):**

```
git add CLAUDE.md docs/TUTORIAL.md   # whichever files changed
git commit -m "$(cat <<'EOF'
Document XDG skill sharing in CLAUDE.md and TUTORIAL.md

Add SKILLS_LINKING.md to the file map. Note sandbox.workspacePath and
the one-time skill clone step in the tutorial.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Full verification checklist

Run this checklist once all steps are complete for a given workspace.

**Host (Mac or Pi):**

```bash
# Symlinks exist and resolve
ls -la ~/projects/ai/<workspace-name>/.claude/skills/
# Each skill entry: symlink → ../../../../.local/share/ai-agents/skills/<name>

readlink -f ~/projects/ai/<workspace-name>/.claude/skills/adr-skill
# /Users/guglielmino.ashar/.local/share/ai-agents/skills/adr-skill  (on Mac)
# /home/pi/.local/share/ai-agents/skills/adr-skill                   (on Pi)

ls ~/projects/ai/<workspace-name>/.claude/skills/adr-skill/
# Skill contents — no error

# Git sees symlinks correctly
git -C ~/projects/ai/<workspace-name> status
# No unexpected modifications. Symlinks appear as committed files.

git -C ~/projects/ai/<workspace-name> show HEAD:.claude/skills/adr-skill
# ../../../../.local/share/ai-agents/skills/adr-skill   (literal string)

# CLI dry-run shows correct paths
cd ~/projects/ai/<workspace-name>
ai-sandbox --dry-run 2>/dev/null | grep 'projects/ai'
# Shows workspace mounted at /home/agent/projects/ai/<workspace-name>

ai-sandbox --dry-run 2>/dev/null | grep 'ai-agents'
# Shows ~/.local/share/ai-agents mounted at /home/agent/.local/share/ai-agents
```

**Inside CLI container:**

```bash
ai-sandbox bash -- bash -c "
  echo 'CWD:' \$(pwd) &&
  echo 'Skills:' \$(ls .claude/skills/) &&
  echo 'Resolved:' \$(readlink -f .claude/skills/adr-skill)
"
# CWD: /home/agent/projects/ai/<workspace-name>
# Skills: adr-skill humanizer ...
# Resolved: /home/agent/.local/share/ai-agents/skills/adr-skill
```

**Inside devcontainer (VS Code terminal):**

```bash
pwd
# /home/agent/projects/ai/<workspace-name>

ls .claude/skills/adr-skill/
# Skill contents — no error

readlink -f .claude/skills/adr-skill
# /home/agent/.local/share/ai-agents/skills/adr-skill
```

**VS Code Explorer:**

Open the workspace in VS Code. In the Explorer, expand `.claude/skills/`. Each skill should appear as a folder (not a file, not missing). If any symlink appears as a broken or unrenderable file, the skill target is not reachable — re-check the XDG data bind mount in devcontainer.json and confirm the skills exist at `~/.local/share/ai-agents/skills/`.

---

### Rollback

If the symlink approach needs to be reverted in a workspace:

```bash
# Remove symlinks
rm .claude/skills/adr-skill .claude/skills/humanizer  # etc.

# Re-add as submodules (or however skills were managed before)
git submodule add <skill-repo-url> .claude/skills/adr-skill

git commit -m "Revert: restore skill submodules"
```

The XDG data directory (`~/.local/share/ai-agents/skills/`) can be left in place — it is harmless and may be reused if the symlink approach is re-adopted.

---

## CLOSED: Automate skill submodule sync across environments

Superseded by the XDG symlinks plan above. See `docs/SKILLS_LINKING.md` for the full record of what was tried and rejected. Short summary:

- **Option A (Monorepo):** Rejected — loses skill independence.
- **Option B (Shell wrapper + postStartCommand):** Rejected — per-machine setup, still requires per-workspace submodule copies.
- **Option C (preLaunch hook in sandbox.json):** Not pursued — symlink approach eliminates the need for any sync step.
