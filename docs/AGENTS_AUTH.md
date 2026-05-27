# Agent Authentication: Design and Validation

This document records what we tried, what failed, why it failed, and where we landed for authenticating AI agents (Claude Code, Codex, and similar tools) in both the CLI sandbox and devcontainer paths. It also covers how to validate whether a credential file is safe to mount read-only.

---

## Goal

AI agent sessions should stay authenticated across:
- Container rebuilds (same workspace, same volume)
- Different workspace folders (open a new project without re-authenticating)
- Simultaneous open workspaces (two VS Code windows, two running containers)

---

## Constraints we will not compromise on

- **No shared host session.** The host machine runs its own agent instances. Containers must not share the host's live OAuth session.
- **No re-login on rebuild.** Rebuilding the devcontainer image or the container itself should not require re-authentication.
- **No per-session conflicts.** Two simultaneously open workspaces must not corrupt each other's home directory state.
- **No broad host filesystem exposure.** The fix must not require mounting `$HOME` or any directory above the credential file into the container.

---

## What we tried and why it failed

### Attempt 1: Bind-mount credentials read-only

```json
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind,readonly"
```

**What happens:** Claude Code reads the access token on startup and appears to work. After roughly one API call, the access token expires. Claude Code tries to write the refreshed token back to the file. The write fails silently (read-only mount). Claude Code cannot recover from the write failure and redirects to the login screen.

**Root cause:** OAuth access tokens are short-lived. Token refresh requires writing the new token back to the credentials file. A read-only mount structurally prevents this.

---

### Attempt 2: Bind-mount credentials read-write

```json
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind"
```

**What happens:** The container starts, reads the host's credentials, and begins working. After a few seconds — just long enough for one or two API calls to succeed — the extension redirects to the login screen.

**Root cause:** OAuth refresh tokens are single-use (or have a very short reuse window). The host machine is also running a Claude Code instance. Both instances hold the same refresh token. Whichever calls the token endpoint first receives a new access token and a new refresh token; the old refresh token is immediately revoked. The other instance then tries to refresh, is rejected with 401 (invalid\_grant), and shows the login screen. Making the file writable does not fix this — it merely changes which instance loses the race.

This is not a file-permissions problem. It is a fundamental incompatibility between a live shared OAuth session and two concurrent consumers.

---

### Attempt 3: Single shared home volume across all workspaces

```json
"source=ai-sandbox-shared-home,target=/home/agent,type=volume"
```

**What happens:** All workspaces share the same `/home/agent`. Credentials persist across workspaces because they live in the same volume.

**Root cause of failure:** When two workspaces are open simultaneously, both containers write to the same `/home/agent`. Session state, shell snapshots, file history, and IDE lock files all conflict.

---

## Current approach

Three volumes plus a bind mount, nested by path specificity:

```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume",
"source=ai-sandbox-shared-codex,target=/home/agent/.codex,type=volume"
```

Additionally, the per-workspace settings file is bind-mounted on top:

```json
"source=${localWorkspaceFolder}/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly"
```

**How Docker resolves nested mounts:** The more specific path always wins. So at runtime:

| Path | Source |
|---|---|
| `/home/agent/**` (except `.claude`, `.codex`) | `${localWorkspaceFolderBasename}-devcontainer-home` — per-workspace, isolated |
| `/home/agent/.claude/**` (except `settings.json`) | `ai-sandbox-shared-claude` — shared across all workspaces |
| `/home/agent/.claude/settings.json` | bind mount from `src/claude-settings.json` — per-workspace |
| `/home/agent/.codex/**` | `ai-sandbox-shared-codex` — shared across all workspaces |

**Result:**
- Workspace home directories are isolated. Simultaneous sessions do not conflict on shell state, harness config, or IDE lock files.
- The Claude session lives exclusively in `ai-sandbox-shared-claude`. One login persists across all workspaces and survives container rebuilds.
- The Codex session lives exclusively in `ai-sandbox-shared-codex`. Same persistence guarantee.
- The host's agent sessions are completely unaffected. Each container's OAuth refresh cycle writes to its own volume.
- Each workspace gets its own tool-permission settings via the bind mount.

**First-time setup:** On first container open (or after `docker volume rm ai-sandbox-shared-claude`), the Claude Code extension prompts for login. VS Code handles the OAuth browser redirect automatically for devcontainers — no manual port forwarding required.

---

## CLI path — short-lived sessions

The CLI (`bin/ai-sandbox`) bind-mounts credential files `:ro` from the host when they exist:

- `~/.claude/.credentials.json` → `/home/agent/.claude/.credentials.json:ro`
- `~/.codex/auth.json` → `/home/agent/.codex/auth.json:ro`

CLI harness sessions are short-lived and do not perform token refresh within a session, so read-only is safe **as long as the credential file contains either static API keys or OAuth tokens with a lifetime longer than a typical session**. See the validation section below to confirm this for any new agent.

The OAuth refresh conflict from Attempt 2 applies to the CLI path too: if a credential file contains OAuth tokens, sharing it read-write between the host agent process and a container would cause the same refresh-token revocation race. The `:ro` mount sidesteps this because the container reads the token once at startup and never refreshes.

---

## Validating the `:ro` approach for new agents

Before adding a `:ro` CLI bind mount for any new credential file, determine whether it contains static credentials or expiring OAuth tokens.

### Step 1 — Inspect the credential format

```bash
jq 'keys' ~/.codex/auth.json   # replace with the relevant file
```

- **Only static key fields** (`api_key`, `token`, `key`): static credentials, never written back by the client. The `:ro` mount is permanently safe. Stop here.
- **OAuth fields** (`access_token`, `refresh_token`, `expires_at`, `expiry`): expiring tokens. Continue to Step 2.
- **JWT string or opaque blob**: treat as potentially expiring. Continue to Step 2.

### Step 2 — Check the access token lifetime

If the file contains an `expires_at` Unix timestamp:

```bash
python3 -c "
import json, datetime
d = json.load(open('$HOME/.codex/auth.json'))
exp = d.get('expires_at') or d.get('expiry') or d.get('token_expiry')
if exp:
    print('expires:', datetime.datetime.fromtimestamp(int(exp)))
else:
    print('no expiry field found — inspect manually')
"
```

- **Expiry hours or days away:** `:ro` CLI mount is safe for short-lived harness sessions. However, the devcontainer runs indefinitely — after the first token expiry, the agent will fail to refresh. Go to Step 3 for devcontainer assessment.
- **Expiry minutes away or already past:** `:ro` CLI mount will fail on the next token refresh attempt. Both paths need remediation — remove the CLI bind mount and add a shared named volume in the devcontainer.

### Step 3 — Observe file writes during a live session

Does the agent write a new token back to the credential file after refreshing?

**Method A — watch mtime:**

```bash
stat -c '%Y %n' ~/.codex/auth.json    # before session
# Run a session long enough to span a token refresh
stat -c '%Y %n' ~/.codex/auth.json    # after session
```

If the mtime changed, the agent writes refreshed tokens back to disk.

**Method B — inotifywait (Linux):**

```bash
inotifywait -m ~/.codex/auth.json -e modify,close_write &
WATCH_PID=$!
# Run a session that spans a token refresh
kill $WATCH_PID
```

If `inotifywait` reports `MODIFY` or `CLOSE_WRITE` events, the agent writes to the file during normal operation.

### Step 4 — Test the `:ro` mount directly

If you cannot wait for a natural token expiry, simulate the failure:

```bash
./bin/ai-sandbox codex --dry-run 2>&1 | head -20
```

If you see a permissions error, auth failure, or immediate non-zero exit, the `:ro` mount is blocking a write the agent needs at startup.

### Decision matrix

| Finding | CLI `:ro` bind mount | Devcontainer |
|---|---|---|
| Static API key | Safe permanently | No action needed |
| OAuth, expiry > session length, no file writes observed | Safe in practice | Needs shared named volume |
| OAuth, expiry > session length, file writes observed | Risky for longer sessions — remove mount | Needs shared named volume |
| OAuth, short expiry or file writes observed immediately | Remove mount | Needs shared named volume |

### Quick-reference commands

```bash
# What type of credential?
jq 'keys' ~/.codex/auth.json

# When does the access token expire?
python3 -c "import json,datetime; d=json.load(open('$HOME/.codex/auth.json')); \
  [print(k,datetime.datetime.fromtimestamp(int(d[k]))) for k in d if 'expir' in k]"

# Has the file changed since last boot?
find ~/.codex -name auth.json -newer /proc/1 2>/dev/null && echo "modified since boot" || echo "unchanged since boot"

# Does the deny rule in claude-settings.json prevent the AI reading it?
jq '[.permissions.deny[] | select(test("codex"))]' src/claude-settings.json
```

---

## Known remaining limitation

`~/.claude/` contains subdirectories (`sessions/`, `file-history/`, `shell-snapshots/`, `telemetry/`) that Claude Code writes to during normal operation. When two workspaces are open simultaneously, both containers write to these paths inside `ai-sandbox-shared-claude`. Session data and history will intermix, and there is a low-probability OAuth token refresh race between the two Claude Code instances (same mechanism as Attempt 2, but between two container instances rather than host and container).

In practice, two workspaces running active Claude Code tasks simultaneously is rare. If it becomes a problem, the next investigation should look at whether Claude.ai's token endpoint supports concurrent refresh from the same account on separate sessions, and whether `~/.claude/sessions/` can be safely shared between concurrent readers.

---

## Files involved

| File | Role |
|---|---|
| `.devcontainer/devcontainer.json` | Devcontainer config for this project |
| `.devcontainer/devcontainer.template.json` | Template for user projects — mounts kept identical to `devcontainer.json` |
| `src/claude-settings.json` | Per-workspace Claude tool permissions, bind-mounted read-only; deny entries block AI from reading auth files |
| `src/Dockerfile` | Creates `/home/agent/.claude` and `/home/agent/.codex` with `agent:agent` ownership so fresh named volumes initialise with correct permissions |
| `bin/ai-sandbox` | CLI path — mounts credential files `:ro` for short-lived harness sessions |
