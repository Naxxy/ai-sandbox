# Workspace Skills: Design and Decisions

This document records the problem context, alternatives considered, and the decision behind how Claude Code skills are shared across workspaces and environments in the ai-sandbox setup. It is a reference for future evolution — read it before changing how skills are stored or linked.

---

## What skills are

Claude Code skills are directories containing a Markdown prompt file and an optional subdirectory of supporting assets. A skill named `foo` is loaded from `.claude/skills/foo.md` (and optionally `.claude/skills/foo/`). Skills extend what Claude Code can do in a given workspace — the `adr-skill` skill adds an ADR workflow, `humanizer` rewrites output style, and so on.

Skills are developed independently and reused across multiple workspaces. A single skill may be active in three or four different project workspaces simultaneously.

---

## The three-environment problem

Every workspace is used in three environments:

| Environment | How it runs | Home directory |
|---|---|---|
| Mac terminal | `ai-sandbox` CLI, no container | `/Users/guglielmino.ashar` |
| Pi terminal | `ai-sandbox` CLI via SSH, no container | `/home/<pi-user>` |
| VS Code devcontainer | devcontainer.json, Docker | `/home/agent` |

Any solution for sharing skills must work in all three environments without per-machine manual steps beyond initial setup.

---

## Approaches considered and rejected

### Submodules

Each workspace carries each skill as a git submodule. Skills stay independent repos; workspaces pin a specific commit.

**Why rejected:** Submodule pointers must be manually updated in every workspace when a skill changes. With three environments, a commit to a skill requires: update pointer in workspace A, workspace B, workspace C, each needing a `git submodule update` on Mac, Pi, and the devcontainer separately. Nine operations for one skill change. In practice, environments drift out of sync.

### Monorepo

Collapse all workspaces and skills into one repository. One `git pull` updates everything everywhere.

**Why rejected:** Skills can no longer be shared as standalone repos or referenced from workspaces outside the monorepo. Also, one large repo means one checkout on every machine — a Pi with limited storage and bandwidth pulls every workspace regardless of need.

### Shell wrapper + `postStartCommand` (submodules automated)

A shell function on Mac and Pi runs `git submodule update --init --remote --merge` before launching the CLI harness. A `postStartCommand` in devcontainer.json runs the same inside the container.

**Why rejected:** Per-machine setup is required (add wrapper to `.zshrc`/`.bashrc`). New machines are not self-configuring. Skills still live inside each workspace repo as submodule copies — an update to a skill still requires touching every workspace.

### Absolute symlinks

Skills live at a fixed absolute path (e.g. `~/.local/share/ai-agents/skills/adr-skill`). Symlinks in workspaces point to that absolute path.

**Why rejected:** The absolute path differs across environments — `/Users/guglielmino.ashar/.local/share/...` on Mac, `/home/pi/.local/share/...` on Pi, `/home/agent/.local/share/...` in the container. A symlink committed with one absolute path is broken in all other environments.

### Relative symlinks with workspace at `/workspace`

The devcontainer and CLI both mount the workspace at `/workspace`. Relative symlinks from `$workspace/skills/<skill>` to the XDG data directory would use a path relative to `/workspace`.

**Why rejected:** `/workspace` is one level from the filesystem root. On the host, the workspace is at `~/projects/ai/<name>/` — three levels from home. The relative path from a symlink in `/workspace/skills/` to `/home/agent/.local/share/...` differs from the relative path from `~/projects/ai/<name>/skills/` to `~/.local/share/...`. The same symlink path string cannot resolve correctly in both the container and the host.

---

## Chosen approach: relative symlinks with depth-matched workspace mounts

Skills live in a single XDG-compliant location on each machine:

```
~/.local/share/ai-agents/skills/
  adr-skill/       ← git repo, cloned once per machine
  humanizer/
  workflow-builder/
```

Each workspace contains symlinks in its `.claude/skills/` directory:

```
~/projects/ai/adr-workspace/.claude/skills/
  adr-skill   →  ../../../../.local/share/ai-agents/skills/adr-skill
  humanizer   →  ../../../../.local/share/ai-agents/skills/humanizer
```

The workspace is mounted inside the container at `/home/agent/projects/ai/<workspace-name>/` — mirroring the depth it has on the host — so the same relative symlink path resolves correctly in all three environments.

---

## Path arithmetic

The critical constraint is that the symlink path from any skill entry to the skills directory must be identical in all environments. Worked out step by step:

**Symlink location on Mac:**
`/Users/guglielmino.ashar/projects/ai/adr-workspace/.claude/skills/adr-skill`

From the symlink's parent (`.claude/skills/`):
- `..` → `.claude/`
- `../..` → `adr-workspace/`
- `../../..` → `projects/ai/`
- `../../../..` → `~/` (`/Users/guglielmino.ashar/`)
- `../../../../.local/share/ai-agents/skills/adr-skill` → `/Users/guglielmino.ashar/.local/share/ai-agents/skills/adr-skill` ✓

**Symlink location on Pi:**
`/home/pi/projects/ai/adr-workspace/.claude/skills/adr-skill`

Same four levels up reaches `/home/pi/`, then `../../../../.local/share/ai-agents/skills/adr-skill` → `/home/pi/.local/share/ai-agents/skills/adr-skill` ✓

**Symlink location in container** (workspace mounted at `/home/agent/projects/ai/adr-workspace/`):
`/home/agent/projects/ai/adr-workspace/.claude/skills/adr-skill`

Same four levels up reaches `/home/agent/`, then `../../../../.local/share/ai-agents/skills/adr-skill` → `/home/agent/.local/share/ai-agents/skills/adr-skill` ✓

All three environments use the same relative path string and it resolves correctly in each — **as long as the workspace is always exactly two levels under the home directory** (i.e. at `~/projects/ai/<name>/`).

---

## XDG storage rationale

`~/.local/share` is the XDG Base Directory Specification's `XDG_DATA_HOME` — the correct location for user data files that applications manage but users also edit directly. Skills are user-edited data shared across multiple tools (workspaces), which fits `XDG_DATA_HOME` precisely. The dotdir-at-home-root convention (`~/.ai-agents/`) used by older tools (nvm, asdf) was considered but rejected in favour of XDG compliance to keep `$HOME` clean.

The full XDG layout:

```
~/.local/share/ai-agents/
  skills/          ← git-managed skill repos (user edits these)
  ai-sandbox/      ← ai-sandbox tool data and config assets
```

---

## Git behaviour with symlinks

Git stores symlinks as blob objects containing the target path string. The target path is recorded verbatim — git does not resolve or validate it at commit or checkout time.

Consequences:
- **Fresh clone with no skills directory:** symlinks exist on disk as dangling pointers. `git clone`, `git checkout`, and `git status` all succeed. `git status` shows no unexpected modifications.
- **After cloning skills:** symlinks start resolving immediately without any git operation on the workspace repo.
- **macOS quirk:** `ln -s` to an existing target on macOS may canonicalise the path. To ensure the relative path is stored verbatim in git, create the symlink with the skills target absent or use `git add` to verify what git actually stored: `git show HEAD:.claude/skills/adr-skill` should output the relative path string.

---

## VS Code behaviour with symlinks

VS Code has no setting to control symlink following in the file explorer (`files.followSymlinks` does not exist). Behaviour is determined solely by whether the symlink target exists at the time VS Code renders the tree:

- **Target exists:** the symlink renders as a normal folder. IntelliSense, file opening, and language servers all follow it correctly.
- **Target absent (dangling):** VS Code omits the entry from the Explorer tree entirely (issue microsoft/vscode#57189, open, no fix planned). The symlink is invisible — it does not show as a broken file, it simply doesn't appear.

**Implication:** skills must be cloned into `~/.local/share/ai-agents/skills/` before the workspace is opened in VS Code. A setup step or README instruction covers this; it is a one-time action per machine.

---

## Required container mounts

For the devcontainer path (devcontainer.json in each workspace):

```json
"workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
"workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
"mounts": [
  "source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
]
```

For the CLI path (sandbox.json in each workspace):

```json
"sandbox": {
  "workspacePath": "/home/agent/projects/ai/<workspace-name>",
  "extraMounts": [
    { "host": "~/.local/share/ai-agents", "container": "/home/agent/.local/share/ai-agents", "readonly": false }
  ]
}
```

Note: the tilde in `host` is expanded by the CLI at runtime using `${extra_host/#\~/$HOME}` — this already works in the current CLI implementation.

---

## Known constraints

1. **Workspace depth is fixed.** The workspace must always be exactly two levels under `~/` — that is, at `~/projects/ai/<name>/`. Moving a workspace to `~/code/<name>/` or nesting it at `~/projects/ai/clients/<name>/` breaks all symlinks because the four-level relative path no longer reaches home.

2. **Skills must be cloned before opening VS Code.** See VS Code behaviour above.

3. **Claude Code skill discovery bug (issue #25367).** Claude Code's skill scanner does not follow symlinks during the discovery/validation phase. Skills registered via symlink may produce "Unknown skill" warnings in the validation pass but execute correctly. This is a Claude Code bug, not a structural problem with this approach.

4. **The container home volume and the XDG bind mount interact.** devcontainer.json for most workspaces mounts a per-workspace named volume at `/home/agent`. The more-specific XDG bind mount at `/home/agent/.local/share/ai-agents` overlays on top of it — Docker's nested mount resolution (more specific path wins) handles this correctly. See `docs/AGENTS_AUTH.md` for the nested mount pattern already in use for `.claude` and `.codex`.

---

## Files involved

| File | Role |
|---|---|
| `docs/SKILLS_LINKING.md` | This document — context and decisions |
| `docs/sandbox-tasks.md` | Implementation task: steps, verification, commit plan |
| `.devcontainer/devcontainer.json` | Per-workspace devcontainer config (one per workspace repo) |
| `.ai-sandbox/sandbox.json` | Per-workspace CLI config (one per workspace repo) |
| `.claude/skills/` | Symlinks to skills live here in each workspace |
| `~/.local/share/ai-agents/skills/` | Canonical skill repos on each machine (not in any git repo) |
