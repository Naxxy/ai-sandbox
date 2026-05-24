# Session Handoff

## Goal

Mount `~/.codex/auth.json` read-only into every sandbox context so the Codex harness can authenticate without re-entering credentials. This mirrors exactly what was already done for `~/.claude/.credentials.json`.

---

## Project summary

`ai-sandbox` is a Bash CLI (`bin/ai-sandbox`) that wraps `docker run` to launch AI agent harnesses inside an isolated Debian container. There are two ways the container is launched:

1. **CLI**: `./bin/ai-sandbox` — reads `.ai-sandbox/sandbox.json`, assembles a `docker run` command, and launches the container.
2. **VS Code devcontainer**: "Rebuild and Reopen in Container" — VS Code reads `.devcontainer/devcontainer.json` directly; the CLI is not involved.

There is also a **devcontainer template** at `.devcontainer/devcontainer.template.json` — a stripped-down reference that users copy when setting up new projects. It needs the same mount.

Both launch paths are independent and must each be updated. The CLI change and the devcontainer change do not share code.

---

## Reference implementation — what was done for `~/.claude/.credentials.json`

Use this as the exact model to follow.

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

### 2. `.devcontainer/devcontainer.json`

This line was added to the `mounts` array:

```json
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind"
```

`${localEnv:HOME}` is the VS Code devcontainer variable that resolves to the host `$HOME` at container startup.

**Important:** The devcontainer mount is read-write (no `readonly`). Claude Code's OAuth session refresh writes updated tokens back to `~/.claude/.credentials.json`. A read-only mount silently breaks token refresh and forces re-login on every container rebuild. The CLI mount in `bin/ai-sandbox` is still `:ro` — harnesses don't perform OAuth refresh, they only read credentials at startup.

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

### 6. `test/test_devcontainer.sh` — `test_credentials_mount_present()` function

Added after `test_claude_settings_mount_readonly()` and called from `main()` immediately after it. Note the name and check: the devcontainer credentials mount is read-write, so this test only verifies presence of the mount, not that `readonly` is set.

```bash
test_credentials_mount_present() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "localEnv:HOME.*\.credentials\.json" \
    && echo "$mounts" | grep -q "target=/home/agent/.claude/.credentials.json"; then
    pass "6.4 security: claude credentials bind-mounted into container"
  else
    fail "6.4 security: claude credentials bind-mounted into container" "mounts: $mounts"
  fi
}
```

---

## Work to implement — `~/.codex/auth.json`

Implement all six changes below, following the reference implementation above exactly. Run the validation commands at the end before declaring done.

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

**Where:** The `mounts` array (currently 4 entries, listed below). Append as the last entry.

Current entries:
```json
"source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
"source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
"source=${localWorkspaceFolder}/src/claude-settings.json,target=/home/agent/.claude/settings.json,type=bind,readonly",
"source=${localEnv:HOME}/.claude/.credentials.json,target=/home/agent/.claude/.credentials.json,type=bind"
```

**What to add** (5th entry):

```json
"source=${localEnv:HOME}/.codex/auth.json,target=/home/agent/.codex/auth.json,type=bind"
```

Note: No `readonly` — VS Code extensions that use OAuth may need to write back refreshed tokens (same reason as the Claude credentials mount).

### Change 3 — `.devcontainer/devcontainer.template.json`

**Where:** The `mounts` array (currently 4 entries, identical to `devcontainer.json` above). Append as the 5th entry.

**What to add:**

```json
"source=${localEnv:HOME}/.codex/auth.json,target=/home/agent/.codex/auth.json,type=bind"
```

The template and `devcontainer.json` have identical mounts sections — keep them in sync. No `readonly` for the same reason as Change 2.

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

### Change 7 — `test/test_devcontainer.sh` — `test_codex_auth_mount_present()` function

**Where:** Add immediately after `test_credentials_mount_present()`. Call it from `main()` immediately after `test_credentials_mount_present`.

```bash
test_codex_auth_mount_present() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "localEnv:HOME.*auth\.json" \
    && echo "$mounts" | grep -q "target=/home/agent/.codex/auth.json"; then
    pass "6.4 security: codex auth bind-mounted into container"
  else
    fail "6.4 security: codex auth bind-mounted into container" "mounts: $mounts"
  fi
}
```

Note: `test_devcontainer.sh` only validates `.devcontainer/devcontainer.json`, not the template file. The template change (Change 3) has no corresponding automated test — verify it by reading the file after editing.

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
Should show five entries: home volume, docker socket, claude-settings, claude-credentials, and codex auth. The template and `devcontainer.json` mounts sections should be identical.

Do not mark this complete based on the code existing alone — only on the validation commands passing.
