# Claude Code Authentication in Devcontainers

This document records what we tried, what failed, why it failed, and where we landed. It exists so future investigations start from known facts rather than re-discovering the same dead ends.

---

## Goal

Claude Code should stay logged in across:
- Container rebuilds (same workspace, same volume)
- Different workspace folders (open a new project without re-authenticating)
- Simultaneous open workspaces (two VS Code windows, two running containers)

---

## Constraints we will not compromise on

- **No shared host session.** The host machine runs its own Claude Code instance. The container must not share the host's live OAuth session.
- **No re-login on rebuild.** Rebuilding the devcontainer image or the container itself should not require re-authentication.
- **No per-session conflicts.** Two simultaneously open workspaces must not corrupt each other's home directory state.
- **No broad host filesystem exposure.** The fix must not require mounting `~HOME` or any directory above the credential file into the container.

---

## What we tried and why it failed

### Attempt 1: Bind-mount `.credentials.json` read-only

```json
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind,readonly"
```

**What happens:** Claude Code reads the access token on startup and appears to work. After roughly one API call, the access token expires. Claude Code tries to write the refreshed token back to the file. The write fails silently (read-only mount). Claude Code cannot recover from the write failure and redirects to the login screen.

**Root cause:** OAuth access tokens are short-lived. Token refresh requires writing the new token back to `.credentials.json`. A read-only mount structurally prevents this.

---

### Attempt 2: Bind-mount `.credentials.json` read-write

```json
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind"
```

**What happens:** The container starts, reads the host's credentials, and begins working. After a few seconds — just long enough for one or two API calls to succeed ("thinking for 2 seconds") — the extension redirects to the login screen.

**Root cause:** OAuth refresh tokens are single-use (or have a very short reuse window). The host machine is also running a Claude Code instance (the user's own session). Both instances hold the same refresh token. Whichever calls the token endpoint first receives a new access token and a new refresh token; the old refresh token is immediately revoked. The other instance then tries to refresh, is rejected with 401 (invalid\_grant), and shows the login screen. Making the file writable does not fix this — it merely changes which instance loses the race.

This is not a file-permissions problem. It is a fundamental incompatibility between a live shared OAuth session and two concurrent consumers.

---

### Attempt 3: Single shared home volume across all workspaces

```json
"source=ai-sandbox-shared-home,target=/home/agent,type=volume"
```

**What happens:** All workspaces share the same `/home/agent`. Claude credentials persist across workspaces because they live in the same volume.

**Root cause of failure:** When two workspaces are open simultaneously, both containers write to the same `/home/agent`. Claude Code's session state, shell snapshots, file history, and IDE lock files (in `~/.claude/ide/`) all conflict. This is the home-directory overlap problem we explicitly do not want to create.

---

## Current approach

Two volumes, nested:

```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume"
```

Additionally, the per-workspace settings file is bind-mounted on top:

```json
"source=${localWorkspaceFolder}/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly"
```

**How Docker resolves nested mounts:** The more specific path always wins. So at runtime:

| Path | Source |
|---|---|
| `/home/agent/**` (except `.claude`) | `${localWorkspaceFolderBasename}-devcontainer-home` — per-workspace, isolated |
| `/home/agent/.claude/**` (except `settings.json`) | `ai-sandbox-shared-claude` — shared across all workspaces |
| `/home/agent/.claude/settings.json` | bind mount from `src/claude-settings.json` — per-workspace |

**Result:**
- Workspace home directories are isolated. Simultaneous sessions do not conflict on shell state, harness config, or IDE lock files.
- The Claude session lives exclusively in `ai-sandbox-shared-claude`. One login persists across all workspaces and survives container rebuilds.
- The host's Claude session is completely unaffected. The container's OAuth refresh cycle writes to its own volume, not to the host's `~/.claude/`.
- Each workspace gets its own tool-permission settings via the bind mount.

**First-time setup:** On first container open (or after `docker volume rm ai-sandbox-shared-claude`), the Claude Code extension prompts for login. VS Code handles the OAuth browser redirect automatically for devcontainers — no manual port forwarding required.

---

## Known remaining limitation

`~/.claude/` contains subdirectories (`sessions/`, `file-history/`, `shell-snapshots/`, `telemetry/`) that Claude Code writes to during normal operation. When two workspaces are open simultaneously, both containers write to these paths inside `ai-sandbox-shared-claude`. Session data and history will intermix, and there is a low-probability OAuth token refresh race between the two Claude Code instances (same mechanism as Attempt 2, but between two container instances rather than host and container).

In practice, two workspaces running active Claude Code tasks simultaneously is rare. If it becomes a problem, the next investigation should look at whether Claude.ai's token endpoint supports concurrent refresh from the same account on separate sessions, and whether `~/.claude/sessions/` can be safely shared between concurrent readers.

---

## Files involved

| File | Role |
|---|---|
| `.devcontainer/devcontainer.json` | Devcontainer config for this project |
| `.devcontainer/devcontainer.template.json` | Template for user projects — kept identical to `devcontainer.json` on mounts |
| `src/claude-settings.json` | Per-workspace Claude tool permissions, bind-mounted read-only |
| `bin/ai-sandbox` | CLI path — mounts `.credentials.json` `:ro` for short-lived harness sessions (no refresh needed) |
