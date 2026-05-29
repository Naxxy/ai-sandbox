# Sandbox Tasks

Implementation tasks for workspace skills migration. Each section is self-contained: a fresh Claude Code instance with access to this file and the relevant workspace codebase can execute it without prior context from earlier conversations.

For the design rationale, path arithmetic, and alternatives considered, read `docs/SKILLS_LINKING.md`. This document covers the *how*; SKILLS_LINKING.md covers the *why*.

---

## Current state

The following work is **complete** — do not re-do it:

- `docs/SKILLS_LINKING.md` — design record and path arithmetic
- AI Sandbox tool repo (`ai-sandbox`):
  - `.devcontainer/devcontainer.json` and `.devcontainer/devcontainer.template.json` — depth-matched `workspaceMount` and `workspaceFolder`; XDG bind mount added
  - `.ai-sandbox/sandbox.json` — `workspacePath` set to `/home/agent/projects/ai/ai-sandbox`; XDG `extraMount` added
  - `bin/ai-sandbox` — `-w "$CFG_WORKSPACE_PATH"` added so the harness starts in the workspace directory
  - `test/test_cli.sh` — two new tests for custom workspacePath and tilde expansion; four existing tests updated
  - `docs/TUTORIAL.md` — `sandbox.workspacePath` and XDG skills setup documented

**Outstanding work** is the migration of workspace repos that still use submodules for skills. The primary outstanding workspace is **adr-workspace**. The same steps apply to any other workspace with skills as submodules.

---

## Skill location conventions

Two conventions exist. Identify which one a workspace uses before starting.

| Convention | Skills directory | Relative symlink depth to reach `~/` |
|---|---|---|
| **Root skills** | `skills/<name>` | `../../../` (3 levels) |
| **Claude Code** | `.claude/skills/<name>` | `../../../../` (4 levels) |

The full symlink target in both cases is `<depth>.local/share/ai-agents/skills/<name>`.

**adr-workspace** uses **root skills** (`skills/<name>`).

---

## Prerequisite: local skills without a git repo

Some skills may exist as local workspace content (a directory or single file) with no remote git repository. The `caveman` skill in adr-workspace is this case — it is currently a single file at `skills/caveman/SKILL.md` with no `.git`.

Before such a skill can be linked via XDG, it needs its own git repository. This requires manual user action:

1. Create a new GitHub repository for the skill (e.g. `caveman-skill`)
2. On Mac:
   ```bash
   mkdir -p ~/.local/share/ai-agents/skills/caveman
   cp ~/projects/ai/adr-workspace/skills/caveman/SKILL.md \
      ~/.local/share/ai-agents/skills/caveman/SKILL.md
   cd ~/.local/share/ai-agents/skills/caveman
   git init && git add SKILL.md
   git commit -m "Initial commit: caveman skill"
   git remote add origin <repo-url>
   git push -u origin main
   ```
3. On Pi: `git clone <repo-url> ~/.local/share/ai-agents/skills/caveman`

Only proceed with the workspace migration steps once the skill's XDG directory exists on the current machine.

---

## TASK: Migrate adr-workspace skills to XDG symlinks

**Host workspace path:** `~/projects/ai/adr-workspace/`

**Container workspace path:** `/home/agent/projects/ai/adr-workspace/`

**Skill convention:** root skills (`skills/<name>`)

**Current state of the workspace:**
- `skills/adr-skill`, `skills/humanizer`, `skills/workflow-builder` are git submodules
- `skills/caveman` is a local directory (single file, no git repo — see prerequisite above)
- `devcontainer.json` uses the old `/workspace` mount target
- No `.ai-sandbox/sandbox.json` (devcontainer-only workspace — Steps 4 and 5 from the generic guide do not apply)

---

### Step A — Machine setup (one-time, per machine, not a commit)

On every machine that will run this workspace (Mac, Pi):

```bash
mkdir -p ~/.local/share/ai-agents/skills
```

Clone each shared skill repo:

```bash
git clone https://github.com/Naxxy/adr-skill.git \
    ~/.local/share/ai-agents/skills/adr-skill
git clone https://github.com/blader/humanizer.git \
    ~/.local/share/ai-agents/skills/humanizer
git clone https://github.com/Naxxy/workspace-builder-skill.git \
    ~/.local/share/ai-agents/skills/workflow-builder
# caveman: see the prerequisite section above
```

**Verification:**

```bash
ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  humanizer  workflow-builder  caveman

ls ~/.local/share/ai-agents/skills/adr-skill/
# Expected: SKILL.md  core/  setup/  (or whatever the repo root contains)
```

---

### Step B — Remove skill submodules

**In the workspace repo** (`~/projects/ai/adr-workspace/`).

```bash
git submodule deinit skills/adr-skill
git submodule deinit skills/humanizer
git submodule deinit skills/workflow-builder
git rm skills/adr-skill skills/humanizer skills/workflow-builder
rm -rf .git/modules/skills/adr-skill \
       .git/modules/skills/humanizer \
       .git/modules/skills/workflow-builder
git rm .gitmodules
```

Remove the local caveman directory (content now lives in the XDG repo):

```bash
rm -rf skills/caveman
```

**Verification:**

```bash
git submodule status
# Expected: empty output

ls skills/
# Expected: empty (no skill directories remain)
```

**Commit:**

```bash
git commit -m "$(cat <<'EOF'
Remove skill submodules (replaced by XDG symlinks)

Skills are now relative symlinks to ~/.local/share/ai-agents/skills/
rather than submodule checkouts. caveman local directory removed — its
content was extracted to a git repo and will be re-added as a symlink.
See docs/SKILLS_LINKING.md in the ai-sandbox repo for the rationale.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Step C — Create XDG symlinks

**In the workspace repo** (`~/projects/ai/adr-workspace/`).

The workspace is at two levels under `~/` (`projects/ai/`), so `skills/` is one level inside the workspace — three levels total from `~/`. The relative path is `../../../.local/share/ai-agents/skills/<name>`.

Path arithmetic (relative path resolves from the symlink's parent directory, `~/projects/ai/adr-workspace/skills/`):
- `..` → `~/projects/ai/adr-workspace/`
- `../..` → `~/projects/ai/`
- `../../..` → `~/`
- `../../../.local/share/ai-agents/skills/adr-skill` → `~/.local/share/ai-agents/skills/adr-skill` ✓

```bash
cd ~/projects/ai/adr-workspace/skills
ln -s ../../../.local/share/ai-agents/skills/adr-skill adr-skill
ln -s ../../../.local/share/ai-agents/skills/humanizer humanizer
ln -s ../../../.local/share/ai-agents/skills/workflow-builder workflow-builder
ln -s ../../../.local/share/ai-agents/skills/caveman caveman
cd ..
```

**Verify the symlinks store the relative path (not an absolute path):**

```bash
git add skills/
git show :"skills/adr-skill"
# Expected: ../../../.local/share/ai-agents/skills/adr-skill
```

If the output is an absolute path, macOS canonicalised the link. Remove and re-create while the XDG target is absent or use `ln -s` from a shell where the target does not exist yet.

**Verify the links resolve:**

```bash
ls -la skills/
# Each entry: symlink → ../../../.local/share/ai-agents/skills/<name>

ls skills/adr-skill/
# Expected: skill contents, no error

readlink -f skills/adr-skill
# Expected: /Users/<user>/.local/share/ai-agents/skills/adr-skill  (on Mac)
```

**Note on nested skills:** `skills/adr-skill/` contains its own `skills/workspace-builder` submodule used during adr-skill development. Do not create a workspace-level symlink for it — `skills/workflow-builder` already provides workspace-builder at the workspace level. The nested reference is the adr-skill repo's internal concern.

**Commit:**

```bash
git commit -m "$(cat <<'EOF'
Link skills via XDG-compliant relative symlinks

Each skill is now a relative symlink from skills/<name> to
~/.local/share/ai-agents/skills/<name>. The three-level relative path
(../../../) resolves correctly on Mac, Pi, and in the devcontainer
once the workspace is mounted at /home/agent/projects/ai/adr-workspace/.
caveman is now linked from its own git repo rather than kept as a local
directory. See docs/SKILLS_LINKING.md in the ai-sandbox repo.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Step D — Update devcontainer.json

**File:** `~/projects/ai/adr-workspace/.devcontainer/devcontainer.json`

Change `workspaceMount` and `workspaceFolder`:

```json
"workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
"workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
```

Add the XDG data bind mount to the `mounts` array (alongside the existing volume mounts):

```json
"source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
```

The full updated file:

```json
{
  "name": "ai-sandbox",
  "runArgs": ["--name", "ai-sandbox-${localWorkspaceFolderBasename}"],
  "image": "ai-sandbox:latest",
  "remoteUser": "agent",
  "workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
  "workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
  "mounts": [
    "source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
    "source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume",
    "source=ai-sandbox-shared-codex,target=/home/agent/.codex,type=volume",
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
    "source=${localEnv:HOME}/.ai-agents/ai-sandbox/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly",
    "source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
  ],
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "openai.chatgpt",
        "rooveterinaryinc.roo-cline"
      ]
    }
  }
}
```

**Verification (rebuild devcontainer, then check in VS Code terminal):**

```bash
pwd
# Expected: /home/agent/projects/ai/adr-workspace

ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  humanizer  workflow-builder  caveman

ls skills/adr-skill/
# Expected: skill contents, no error

readlink -f skills/adr-skill
# Expected: /home/agent/.local/share/ai-agents/skills/adr-skill

# CLAUDE.md routing paths still resolve
cat skills/adr-skill/SKILL.md | head -3
# Expected: skill content
```

**VS Code Explorer:** Expand `skills/`. Each skill should appear as a folder with its contents visible. If an entry is missing entirely, the XDG bind mount is not working — check that `~/.local/share/ai-agents` exists on the host and the bind mount entry is correct.

**Commit:**

```bash
git add .devcontainer/devcontainer.json
git commit -m "$(cat <<'EOF'
Update devcontainer: depth-matched workspace mount and XDG skills bind

Mount workspace at /home/agent/projects/ai/adr-workspace/ so the
three-level relative symlinks in skills/ resolve correctly inside the
container. Bind-mount ~/.local/share/ai-agents so skill targets are
present. See docs/SKILLS_LINKING.md in the ai-sandbox repo.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Full verification checklist — adr-workspace

**Host (Mac or Pi):**

```bash
# Symlinks resolve
ls -la ~/projects/ai/adr-workspace/skills/
# Each entry: <name> -> ../../../.local/share/ai-agents/skills/<name>

readlink -f ~/projects/ai/adr-workspace/skills/adr-skill
# /Users/<user>/.local/share/ai-agents/skills/adr-skill  (Mac)
# /home/pi/.local/share/ai-agents/skills/adr-skill         (Pi)

ls ~/projects/ai/adr-workspace/skills/adr-skill/
# Skill contents — no error

# Git records the relative path string, not an absolute path
git -C ~/projects/ai/adr-workspace show HEAD:skills/adr-skill
# ../../../.local/share/ai-agents/skills/adr-skill

# No submodules remain
git -C ~/projects/ai/adr-workspace submodule status
# (empty)

# CLAUDE.md routing paths resolve
ls ~/projects/ai/adr-workspace/skills/adr-skill/SKILL.md
# File exists and is readable
```

**Inside devcontainer (VS Code terminal):**

```bash
pwd
# /home/agent/projects/ai/adr-workspace

readlink -f skills/adr-skill
# /home/agent/.local/share/ai-agents/skills/adr-skill

ls skills/humanizer/ && ls skills/workflow-builder/ && ls skills/caveman/
# All resolve — no errors
```

---

### Rollback — adr-workspace

```bash
# Remove symlinks
rm skills/adr-skill skills/humanizer skills/workflow-builder skills/caveman

# Re-add as submodules
git submodule add https://github.com/Naxxy/adr-skill.git skills/adr-skill
git submodule add https://github.com/blader/humanizer.git skills/humanizer
git submodule add https://github.com/Naxxy/workspace-builder-skill.git skills/workflow-builder

# Restore caveman as local directory
mkdir skills/caveman
cp ~/.local/share/ai-agents/skills/caveman/SKILL.md skills/caveman/SKILL.md

git commit -m "Revert: restore skill submodules"
```

The XDG directory (`~/.local/share/ai-agents/skills/`) can be left in place — it is harmless and reusable if the symlink approach is re-adopted.

---

## TASK: Apply the same migration to other workspaces

For any other workspace that has skills as submodules or local directories:

1. Identify the skill convention — check whether skills are in `skills/` or `.claude/skills/`
2. Run the machine setup step (Step A above) for any new skill repos
3. Handle any local-only skills the same way as caveman (extract to git repo first)
4. Follow Steps B–D above, substituting the correct workspace name and symlink depth:
   - `skills/<name>` convention: `../../../.local/share/ai-agents/skills/<name>`
   - `.claude/skills/<name>` convention: `../../../../.local/share/ai-agents/skills/<name>`

**Constraint:** the workspace must sit at exactly `~/projects/ai/<name>/` on every machine (two levels under home). If it is at a different depth, the relative symlink path changes. See the path arithmetic section of `docs/SKILLS_LINKING.md` in the ai-sandbox repo before proceeding.

---

## CLOSED: Automate skill submodule sync across environments

Superseded by the XDG symlinks plan above. See `docs/SKILLS_LINKING.md` for the full record of what was tried and rejected. Short summary:

- **Option A (Monorepo):** Rejected — loses skill independence.
- **Option B (Shell wrapper + postStartCommand):** Rejected — per-machine setup, still requires per-workspace submodule copies.
- **Option C (preLaunch hook in sandbox.json):** Not pursued — symlink approach eliminates the need for any sync step.
