# Migration guide: submodule skills → XDG symlinks

For the design rationale and path arithmetic behind this approach, read
`docs/SKILLS_LINKING.md`. This document covers the *how*; SKILLS_LINKING.md
covers the *why*.

This guide is written from the perspective of someone inside a running
devcontainer **before** it has been rebuilt with the updated `devcontainer.json`.
Skills are currently inaccessible (dangling symlinks) until the rebuild in step 3.

---

## What changed

Previously, `skills/` held git submodules and/or local directories. The
workspace repo owned their content and required `git submodule update --init`
on every machine.

Now, `skills/` holds relative symlinks into a shared XDG directory:

```
skills/<name>  →  ../../../.local/share/ai-agents/skills/<name>
```

The prefix depth depends on how many levels the workspace sits below `~/`.
For a workspace at `~/projects/ai/<name>/` (two levels), the prefix is
`../../../` (three levels back to `~/`). See `docs/SKILLS_LINKING.md` for the
full path arithmetic.

The updated `devcontainer.json` makes this work by:
- mounting the workspace at `/home/agent/projects/ai/<name>/` instead of
  `/workspace`, so the relative prefix resolves correctly inside the container
- bind-mounting `~/.local/share/ai-agents` from the host into the container at
  `/home/agent/.local/share/ai-agents`, so the skill repos are visible at the
  symlink targets

---

## Step 1 — Set up the XDG skills directory on the host

Run these commands from a host terminal (not inside the container).

```bash
mkdir -p ~/.local/share/ai-agents/skills
```

Clone each git-backed skill that this workspace uses. For adr-workspace:

```bash
git clone https://github.com/Naxxy/adr-skill.git \
    ~/.local/share/ai-agents/skills/adr-skill

git clone https://github.com/blader/humanizer.git \
    ~/.local/share/ai-agents/skills/humanizer

git clone https://github.com/Naxxy/workspace-builder-skill.git \
    ~/.local/share/ai-agents/skills/workflow-builder
```

For a different workspace, substitute the skill repos and names listed in that
workspace's `CLAUDE.md` routing table.

**Verify:**

```bash
ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  humanizer  workflow-builder  (plus any local-only skills after step 2)
```

---

## Step 2 — Handle local-only skills

Some skills have no git remote (e.g. `caveman` in adr-workspace — a single
`SKILL.md` file that was committed directly in the workspace repo).

For each such skill, create its directory at the XDG path and populate it:

```bash
mkdir -p ~/.local/share/ai-agents/skills/<name>
# then write or copy SKILL.md into that directory
```

For `caveman` specifically, the full `SKILL.md` content is recoverable from the
workspace repo's git history:

```bash
git show <last-commit-before-removal>:skills/caveman/SKILL.md \
    > ~/.local/share/ai-agents/skills/caveman/SKILL.md
```

In adr-workspace the commit to use is `055677e` (the last commit that contained
`skills/caveman/SKILL.md`):

```bash
git -C ~/projects/ai/adr-workspace show 055677e:skills/caveman/SKILL.md \
    > ~/.local/share/ai-agents/skills/caveman/SKILL.md
```

If you want to version-control the skill going forward, `git init` and push from
`~/.local/share/ai-agents/skills/<name>/`. The symlink requires no changes.

**Verify:**

```bash
ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  caveman  humanizer  workflow-builder
```

---

## Step 3 — Rebuild the devcontainer

From VS Code on the host:

**Command Palette → "Dev Containers: Rebuild Container"**

This is the step that activates both changes. Until the rebuild, skills symlinks
remain dangling inside the current container.

---

## Step 4 — Verify inside the rebuilt container

Open a terminal in the new container and run:

```bash
pwd
# Expected: /home/agent/projects/ai/adr-workspace

ls ~/.local/share/ai-agents/skills/
# Expected: adr-skill  caveman  humanizer  workflow-builder

ls skills/adr-skill/
# Expected: skill repo contents — no error

readlink -f skills/adr-skill
# Expected: /home/agent/.local/share/ai-agents/skills/adr-skill

ls skills/humanizer/ && ls skills/workflow-builder/ && ls skills/caveman/
# All resolve — no errors
```

If any skill directory is missing, the XDG bind mount is not working. Check that
`~/.local/share/ai-agents` exists on the host (step 1) and that the container was
fully rebuilt rather than just restarted.

---

## Ongoing: updating skills

Skills are now standalone git repos on the host. Pull updates directly:

```bash
git -C ~/.local/share/ai-agents/skills/adr-skill pull
git -C ~/.local/share/ai-agents/skills/humanizer pull
git -C ~/.local/share/ai-agents/skills/workflow-builder pull
```

No workspace commit is needed. Updates are visible immediately inside any
running container that has the XDG bind mount active.

---

## On a new machine (Pi, second Mac, etc.)

1. Repeat steps 1 and 2 on the new machine.
2. Open the workspace in VS Code — the devcontainer builds automatically on first
   open.
3. Run the step 4 verification.

There is no `git submodule update --init` step. The workspace repo contains only
symlinks; the skill content lives in the XDG directory you populated in steps 1–2.
