# Workspace Skills: Design and Decisions

Skills are Claude Code directories (`.claude/skills/<name>.md`) reused across multiple workspaces. This document records why the current approach was chosen — read it before changing how skills are stored or linked.

---

## Three environments

| Environment | How it runs | Home directory |
|---|---|---|
| Mac terminal | `ai-sandbox` CLI | `/Users/guglielmino.ashar` |
| Pi terminal | `ai-sandbox` CLI via SSH | `/home/<pi-user>` |
| VS Code devcontainer | devcontainer.json, Docker | `/home/agent` |

Any solution must work in all three without per-machine manual steps beyond initial setup.

---

## Approaches rejected

| Approach | Why |
|---|---|
| Submodules | One skill change = 9 manual operations (3 workspaces × 3 envs); drift inevitable |
| Monorepo | Skills can't be shared outside it; Pi pulls every workspace |
| Shell wrapper + `postStartCommand` | Per-machine shell config required; skill copies still live in each workspace |
| Absolute symlinks | Home path differs per environment; a committed absolute symlink is broken everywhere else |
| Relative symlinks at `/workspace` | Container mounts workspace at `/workspace` (1 level from root); host path is `~/projects/ai/<name>/` (3 levels from home); same relative path string can't reach home in both |

---

## Chosen approach: relative symlinks with depth-matched mounts

Skills live at a single XDG location on each machine:

```
~/.local/share/ai-agents/skills/
  adr-skill/       ← git repo, cloned once per machine
  humanizer/
  workflow-builder/
```

Each workspace symlinks into it:

```
~/projects/ai/adr-workspace/.claude/skills/
  adr-skill   →  ../../../../.local/share/ai-agents/skills/adr-skill
  humanizer   →  ../../../../.local/share/ai-agents/skills/humanizer
```

The workspace is mounted at `/home/agent/projects/ai/<name>/` inside the container — mirroring its host depth — so the same four-level relative path reaches `~/` in all three environments.

---

## Path arithmetic

The symlink's parent is `.claude/skills/`. Four `..` steps: `.claude/` → workspace root → `projects/ai/` → `~/`. This is identical whether `~/` is `/Users/guglielmino.ashar`, `/home/pi`, or `/home/agent`, **as long as the workspace sits exactly two levels under home** (`~/projects/ai/<name>/`).

Worked out for the container environment:
- Symlink: `/home/agent/projects/ai/adr-workspace/.claude/skills/adr-skill`
- `../../../../.local/share/ai-agents/skills/adr-skill` → `/home/agent/.local/share/ai-agents/skills/adr-skill` ✓

Same arithmetic applies on Mac and Pi — only the home prefix differs.

---

## XDG rationale

`~/.local/share` is `XDG_DATA_HOME` — the correct location for user-managed data shared across tools. Skills are user-edited and shared across workspaces, which fits precisely. The `~/.ai-agents/` dotdir convention (used by nvm, asdf) was rejected to keep `$HOME` clean.

---

## Git behaviour

- **Fresh clone (skills not yet cloned):** symlinks are dangling pointers. `git clone`, `checkout`, and `status` all succeed; `status` shows no modifications.
- **After cloning skills:** symlinks resolve immediately — no git operation on the workspace repo needed.
- **macOS:** `ln -s` to an existing target may canonicalise to an absolute path. Verify with `git show HEAD:.claude/skills/adr-skill` — output must be the relative path string, not an absolute path.

---

## VS Code behaviour

VS Code follows symlinks when the target exists, regardless of whether the path is relative or absolute:

- **Target exists:** renders as a normal folder; IntelliSense and language servers follow it correctly. Relative symlinks resolve correctly — VS Code follows path arithmetic from the symlink's on-disk location identically to absolute symlinks.
- **Target absent:** entry is omitted from Explorer entirely (issue microsoft/vscode#57189, no fix planned) — invisible, not shown as broken.

Skills must be cloned into `~/.local/share/ai-agents/skills/` before opening the workspace in VS Code. The relative path syntax is not the constraint — a present target via a relative symlink shows up exactly as expected.

---

## Required container mounts

devcontainer.json:
```json
"workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
"workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
"mounts": [
  "source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
]
```

sandbox.json:
```json
"sandbox": {
  "workspacePath": "/home/agent/projects/ai/<workspace-name>",
  "extraMounts": [
    { "host": "~/.local/share/ai-agents", "container": "/home/agent/.local/share/ai-agents", "readonly": false }
  ]
}
```

The tilde in `host` is expanded at runtime by the CLI (`${extra_host/#\~/$HOME}`).

---

## Known constraints

1. **Workspace depth is fixed** at `~/projects/ai/<name>/` (two levels under home). Any other depth breaks the four-level relative path.
2. **Skills must be cloned before opening VS Code.** Relative symlinks display correctly once targets exist — dangling pointers are invisible in Explorer.
3. **Claude Code skill discovery bug (issue #25367).** Symlinked skills may produce "Unknown skill" warnings in the validation pass but execute correctly.
4. **Nested mount interaction.** The per-workspace named volume at `/home/agent` and the XDG bind mount at `/home/agent/.local/share/ai-agents` coexist — Docker's more-specific-path-wins rule handles this. See `docs/AGENTS_AUTH.md`.

---

## Files involved

| File | Role |
|---|---|
| `docs/SKILLS_LINKING.md` | This document — context and decisions |
| `docs/sandbox-tasks.md` | Migration steps, verification, commit plan |
| `.devcontainer/devcontainer.json` | Per-workspace devcontainer config |
| `.ai-sandbox/sandbox.json` | Per-workspace CLI config |
| `.claude/skills/` | Symlinks live here in each workspace |
| `~/.local/share/ai-agents/skills/` | Canonical skill repos on each machine (not in any git repo) |
