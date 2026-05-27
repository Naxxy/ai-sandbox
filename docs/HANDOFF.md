# Session Handoff

## Goal

Mount `~/.codex/auth.json` read-only into the CLI sandbox context so the Codex harness can authenticate without re-entering credentials. This mirrors what was done for `~/.claude/.credentials.json` in `bin/ai-sandbox`.

---

## Project summary

`ai-sandbox` is a Bash CLI (`bin/ai-sandbox`) that wraps `docker run` to launch AI agent harnesses inside an isolated Debian container. There are two ways the container is launched:

1. **CLI**: `./bin/ai-sandbox` — reads `.ai-sandbox/sandbox.json`, assembles a `docker run` command, and launches the container.
2. **VS Code devcontainer**: "Rebuild and Reopen in Container" — VS Code reads `.devcontainer/devcontainer.json` directly; the CLI is not involved.

There is also a **devcontainer template** at `.devcontainer/devcontainer.template.json` — a stripped-down reference that users copy when setting up new projects. It needs the same mount.

Both launch paths are independent and must each be updated. The CLI change and the devcontainer change do not share code.

---

## Reference implementation — what was done for `~/.claude/.credentials.json`

Use this as the **exact model** for the CLI path. The devcontainer path is intentionally different — read the note below before following this for devcontainer changes.

### 1. `bin/ai-sandbox`

After the claude-settings block (around line 279), this block was added:

```bash
local claude_creds="${HOME}/.claude/.credentials.json"
if [[ -f "$claude_creds" ]]; then
  cmd+=(-v "${claude_creds}:/home/agent/.claude/.credentials.json:ro")
  echo "[sandbox] claude credentials mounted read-only" >&2
fi
```

Rules that apply (from CLAUDE.md):
- No `set -euo pipefail` — use explicit `[[ -f ... ]]` guards.
- Use `echo` for stderr diagnostic messages (not `printf`).
- The mount is a no-op if the file doesn't exist on the host.
- `:ro` is intentional — CLI harnesses are short-lived; they read the access token at startup but never perform OAuth token refresh. Read-only is safe for them.

### 2. `.devcontainer/devcontainer.json`

**No credentials bind mount.** The devcontainer deliberately does NOT bind-mount `~/.claude/.credentials.json` from the host.

**Why:** OAuth refresh tokens are single-use (or have a short reuse window). The host machine and the devcontainer each run their own Claude Code instance. If they share the same credentials file, whichever instance refreshes the token first revokes the refresh token the other holds in memory. The other instance then fails mid-task with a 401 and shows the login screen. Making the mount read-write does not fix this — it just changes which side loses the refresh race. Full investigation in `docs/CLAUDE_AUTH.md`.

**The right model:** The `mounts` array uses two volumes:

```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume"
```

- The per-workspace volume (`${localWorkspaceFolderBasename}-devcontainer-home`) isolates shell state, harness config, and IDE lock files between simultaneously open workspaces.
- The shared volume (`ai-sandbox-shared-claude`) mounts at `/home/agent/.claude` and is shared across all workspaces. Claude Code stores and refreshes its OAuth session here. One login persists across all workspaces and survives rebuilds.
- Docker resolves nested mounts by specificity: the `.claude` volume shadows the `.claude/` directory inside the workspace volume; the `settings.json` bind mount (listed after) shadows `settings.json` inside the shared Claude volume.

The first time a workspace opens against a fresh `ai-sandbox-shared-claude` volume, the Claude Code extension prompts for login. VS Code handles the OAuth browser redirect automatically for devcontainers.

### 3. `src/claude-settings.json`

Two deny entries were added to prevent the AI from reading the credentials file via the Read tool (Claude Code itself reads it internally at startup, unaffected by these rules):

```json
"Read(~/.claude/.credentials.json)",
"Read(/home/agent/.claude/.credentials.json)",
```

These were inserted before the existing `Write` and `Edit` deny entries for `settings.json`.

### 4. `test/run_tests.sh` — mount count

The baseline `-v` count in `test_extra_mounts` was updated from a hardcoded `4` to a conditional that accounts for optional credential mounts:

```bash
expected_v=4
[[ -f "${HOME}/.claude/.credentials.json" ]] && expected_v=$((expected_v + 1))
```

### 5. `test/run_tests.sh` — `test_credentials()` function

A new test function was added before `main()` and called from `main()` between `test_claude_settings` and `test_sudo`:

```bash
test_credentials() {
  local creds_file="${HOME}/.claude/.credentials.json"

  if [[ ! -f "$creds_file" ]]; then
    return
  fi

  local out exit_code
  out=$(cli_dry | tail -1)
  if echo "$out" | grep -q "\.credentials\.json:/home/agent/\.claude/\.credentials\.json:ro"; then
    pass "credentials: file mounted :ro in dry-run"
  else
    fail "credentials: file mounted :ro in dry-run" "got: $out"
  fi

  out=$(cli_dry2)
  if echo "$out" | grep -q "claude credentials mounted read-only"; then
    pass "credentials: [sandbox] log message on stderr"
  else
    fail "credentials: [sandbox] log message on stderr" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "test -s /home/agent/.claude/.credentials.json && echo ok" 2>/dev/null)
  if [[ "$out" == "ok" ]]; then
    pass "credentials: file present and non-empty inside container"
  else
    fail "credentials: file present and non-empty inside container" "got: $out"
  fi

  "$CLI" --shell -- bash -c "echo x > /home/agent/.claude/.credentials.json" > /dev/null 2>&1
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    pass "credentials: write blocked by :ro bind mount"
  else
    fail "credentials: write blocked by :ro bind mount" "write succeeded unexpectedly"
  fi
}
```

### 6. `test/test_devcontainer.sh`

No credentials test exists in `test_devcontainer.sh`. The devcontainer deliberately has no credentials bind mount (see reference section 2 above), so there is nothing to validate here.

---

## Work to implement — `~/.codex/auth.json`

Implement all changes below. The codex auth work follows the same split as claude credentials: CLI gets a `:ro` bind mount; devcontainer does NOT bind-mount credentials. Run the validation commands at the end before declaring done.

### Change 1 — `bin/ai-sandbox`

**Where:** In the `build_docker_cmd` function, immediately after the existing claude credentials block (which ends with the `fi` closing `if [[ -f "$claude_creds" ]]`).

**What to add:**

```bash
local codex_auth="${HOME}/.codex/auth.json"
if [[ -f "$codex_auth" ]]; then
  cmd+=(-v "${codex_auth}:/home/agent/.codex/auth.json:ro")
  echo "[sandbox] codex auth mounted read-only" >&2
fi
```

Note: `/home/agent/.codex/` does not exist in the image. Docker creates the parent directory automatically for bind mounts targeting a file path, so no Dockerfile change is needed.

### Change 2 — `.devcontainer/devcontainer.json`

**No change needed.** The devcontainer does not bind-mount session credentials. If the Codex VS Code extension (if one exists) needs its own auth, it authenticates independently and stores credentials in the named volume — exactly like Claude Code does.

Current mounts (4 entries — do not add a codex entry):
```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume",
"source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
"source=${localWorkspaceFolder}/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly"
```

### Change 3 — `.devcontainer/devcontainer.template.json`

**No change needed.** Template and `devcontainer.json` mounts are identical (same 4 entries). Neither has credential bind mounts.

### Change 4 — `src/claude-settings.json`

**Where:** The `deny` array, before the existing `Write` and `Edit` entries for `settings.json`.

**What to add** (two entries, modelled on the claude credentials deny rules):

```json
"Read(~/.codex/auth.json)",
"Read(/home/agent/.codex/auth.json)",
```

### Change 5 — `test/run_tests.sh` — mount count

**Where:** The `test_extra_mounts` function. The current baseline count logic is:

```bash
expected_v=4
[[ -f "${HOME}/.claude/.credentials.json" ]] && expected_v=$((expected_v + 1))
```

**Replace with:**

```bash
expected_v=4
[[ -f "${HOME}/.claude/.credentials.json" ]] && expected_v=$((expected_v + 1))
[[ -f "${HOME}/.codex/auth.json" ]] && expected_v=$((expected_v + 1))
```

Also update the comment above it from:
```bash
# Empty extraMounts → baseline -v flags: workspace + sandbox.json:ro + home + claude-settings:ro [+ credentials:ro if present]
```
to:
```bash
# Empty extraMounts → baseline -v flags: workspace + sandbox.json:ro + home + claude-settings:ro [+ optional credential mounts]
```

### Change 6 — `test/run_tests.sh` — `test_codex_auth()` function

**Where:** Add this function immediately after the existing `test_credentials()` function and before `main()`. Then add a call to `test_codex_auth` in `main()` immediately after `test_credentials`.

```bash
test_codex_auth() {
  local auth_file="${HOME}/.codex/auth.json"

  if [[ ! -f "$auth_file" ]]; then
    return
  fi

  local out exit_code
  out=$(cli_dry | tail -1)
  if echo "$out" | grep -q "auth\.json:/home/agent/\.codex/auth\.json:ro"; then
    pass "codex-auth: file mounted :ro in dry-run"
  else
    fail "codex-auth: file mounted :ro in dry-run" "got: $out"
  fi

  out=$(cli_dry2)
  if echo "$out" | grep -q "codex auth mounted read-only"; then
    pass "codex-auth: [sandbox] log message on stderr"
  else
    fail "codex-auth: [sandbox] log message on stderr" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "test -s /home/agent/.codex/auth.json && echo ok" 2>/dev/null)
  if [[ "$out" == "ok" ]]; then
    pass "codex-auth: file present and non-empty inside container"
  else
    fail "codex-auth: file present and non-empty inside container" "got: $out"
  fi

  "$CLI" --shell -- bash -c "echo x > /home/agent/.codex/auth.json" > /dev/null 2>&1
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    pass "codex-auth: write blocked by :ro bind mount"
  else
    fail "codex-auth: write blocked by :ro bind mount" "write succeeded unexpectedly"
  fi
}
```

### Change 7 — `test/test_devcontainer.sh`

**No change needed.** The devcontainer does not bind-mount codex auth (same design as claude credentials — see Change 2). Do not add a `test_codex_auth_mount_present` function. There is nothing to test in `test_devcontainer.sh` for this feature.

---

## Validation

Run from the project root after all changes:

```bash
bash test/run_tests.sh
bash test/test_devcontainer.sh
```

Both must end with `0 failed`. If `~/.codex/auth.json` does not exist on the host machine, the `test_codex_auth` and mount-count tests will silently skip — that is correct behaviour (graceful no-op when the file is absent).

To verify the devcontainer template manually:
```bash
jq '.mounts' .devcontainer/devcontainer.template.json
```
Should show four entries: per-workspace home volume, shared claude volume, docker socket, and claude-settings (readonly). The template and `devcontainer.json` mounts sections should be identical. No credential bind mounts should appear.

Do not mark this complete based on the code existing alone — only on the validation commands passing.

---

## If validation shows the shared volume approach is needed

Run `VALIDATE.md` first to determine whether Codex uses expiring OAuth tokens that require write-back. If it does, the devcontainer needs a shared named volume (same pattern as `ai-sandbox-shared-claude`). The CLI bind mount may also need removing if access token lifetime is shorter than a typical harness session.

### Rollback — removing the CLI bind mount

Only do this if Step 2 or Step 3 of `VALIDATE.md` shows that Codex writes refreshed tokens back to `auth.json` and the token lifetime is short enough to expire mid-session. If the token outlives typical CLI sessions, the `:ro` mount is safe and this rollback is not needed.

**`bin/ai-sandbox`** — remove the codex block added in Change 1:

```bash
local codex_auth="${HOME}/.codex/auth.json"
if [[ -f "$codex_auth" ]]; then
  cmd+=(-v "${codex_auth}:/home/agent/.codex/auth.json:ro")
  echo "[sandbox] codex auth mounted read-only" >&2
fi
```

**`src/claude-settings.json`** — keep the deny entries even after removing the bind mount. They are harmless when the file is absent and act as forward protection if the mount is ever re-added:

```json
"Read(~/.codex/auth.json)",
"Read(/home/agent/.codex/auth.json)",
```

**`test/run_tests.sh`** — remove the `test_codex_auth` function, remove its call from `main()`, and remove the codex line from the mount count:

```bash
[[ -f "${HOME}/.codex/auth.json" ]] && expected_v=$((expected_v + 1))
```

Revert the comment back to:

```bash
# Empty extraMounts → baseline -v flags: workspace + sandbox.json:ro + home + claude-settings:ro [+ credentials:ro if present]
```

### Shared volume path — devcontainer

Add a named volume for Codex auth nested under the workspace home volume. Docker's specificity rule makes `/home/agent/.codex` resolve from the shared volume while the rest of `/home/agent` comes from the per-workspace volume — same mechanism as `ai-sandbox-shared-claude`.

**`.devcontainer/devcontainer.json` and `.devcontainer/devcontainer.template.json`** — add after the `ai-sandbox-shared-claude` entry:

```json
"source=ai-sandbox-shared-codex,target=/home/agent/.codex,type=volume",
```

Mounts array becomes 5 entries (order matters — more specific paths must follow less specific ones):

```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume",
"source=ai-sandbox-shared-codex,target=/home/agent/.codex,type=volume",
"source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
"source=${localWorkspaceFolder}/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly"
```

**`test/test_devcontainer.sh`** — add a test function immediately before `main()` and call it from `main()` after `test_agent_home_volume_mount`:

```bash
test_codex_volume_mount() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "target=/home/agent/.codex" \
    && echo "$mounts" | grep "target=/home/agent/.codex" | grep -q "type=volume"; then
    pass "codex-auth: ai-sandbox-shared-codex volume mounted at /home/agent/.codex"
  else
    fail "codex-auth: ai-sandbox-shared-codex volume mounted at /home/agent/.codex" "mounts: $mounts"
  fi
}
```

Also update `test_no_host_home_in_mounts_array` to verify no bind-mount of `~/.codex` crept in — the existing regex already blocks bare home paths, but confirm the codex volume entry passes the security check.

**First-time setup:** On first container open (or after `docker volume rm ai-sandbox-shared-codex`), Codex will prompt for login if it has an interactive auth flow. If it requires an API key entry, the user configures it once inside the container and it persists in the named volume across rebuilds.

**Validation after implementing the shared volume:**

```bash
bash test/test_devcontainer.sh
jq '.mounts' .devcontainer/devcontainer.json
jq '.mounts' .devcontainer/devcontainer.template.json
```

Both `jq` outputs must be identical and show exactly 5 entries. `test_devcontainer.sh` must end with `0 failed`.
