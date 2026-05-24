# Codex Auth Validation

## Question

Does `~/.codex/auth.json` contain static credentials (an API key) or expiring OAuth tokens that require periodic refresh? The answer determines whether the current `:ro` CLI bind mount is safe, and whether the devcontainer needs a shared named volume (`ai-sandbox-shared-codex`).

---

## Step 1 — Inspect the credential format

```bash
jq 'keys' ~/.codex/auth.json
```

**If you see only static key fields** (e.g. `api_key`, `token`, `key`):
Static credentials — they do not expire and are never written back by the client. The `:ro` CLI bind mount is permanently safe. No shared volume is needed. **Stop here.**

**If you see OAuth fields** (e.g. `access_token`, `refresh_token`, `expires_at`, `expiry`):
Expiring OAuth tokens. Continue to Step 2.

**If the file is a JWT string or opaque blob:**
Treat it as potentially expiring. Continue to Step 2.

---

## Step 2 — Check the access token lifetime

If `auth.json` contains an `expires_at` Unix timestamp:

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

**If expiry is hours or days away:** The `:ro` CLI mount is safe for short-lived harness sessions (typical sessions last minutes). However, the devcontainer runs indefinitely — after the first token expiry, Codex will fail to refresh and show an auth error. Go to Step 3 for devcontainer assessment.

**If expiry is minutes away or already past:** The `:ro` CLI mount will fail on the next token refresh attempt. Both paths need remediation. Follow the rollback and shared-volume sections in HANDOFF.md.

---

## Step 3 — Observe file writes during a live session

The key question: does Codex write a new token back to `auth.json` after refreshing?

**Method A — watch mtime:**

```bash
# Before a session
stat -c '%Y %n' ~/.codex/auth.json

# Run a Codex CLI session long enough to trigger a token refresh
# (for OAuth, wait until past the access token expiry from Step 2)

# After the session
stat -c '%Y %n' ~/.codex/auth.json
```

If the mtime changed, Codex writes refreshed tokens back to the file.

**Method B — inotifywait (Linux):**

```bash
inotifywait -m ~/.codex/auth.json -e modify,close_write &
WATCH_PID=$!

# Run a Codex CLI session that spans a token refresh

kill $WATCH_PID
```

If `inotifywait` reports `MODIFY` or `CLOSE_WRITE` events, Codex writes to the file during normal operation.

---

## Step 4 — Test the :ro mount directly

If you cannot wait for a natural token expiry, simulate what happens when the write is blocked:

```bash
# Temporarily mount auth.json :ro in a container and attempt a refresh-triggering action
# The easiest proxy: check whether codex exits cleanly or errors on startup
./bin/ai-sandbox codex --dry-run 2>&1 | head -20
```

If you see a permissions error, auth failure, or the process immediately exits non-zero, the `:ro` mount is blocking a write Codex needs at startup.

---

## Decision matrix

| Finding | CLI `:ro` bind mount | Devcontainer |
|---|---|---|
| Static API key | Safe permanently | No action needed |
| OAuth, expiry > session length, no file writes observed | Safe in practice | Needs shared volume — see HANDOFF.md |
| OAuth, expiry > session length, file writes observed | Risky for longer sessions — see rollback | Needs shared volume — see HANDOFF.md |
| OAuth, short expiry or file writes observed immediately | Follow rollback in HANDOFF.md | Needs shared volume — see HANDOFF.md |

---

## Quick-reference commands

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
