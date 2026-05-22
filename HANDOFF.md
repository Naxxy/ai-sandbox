# Session Handoff

## What this file is

This document captures the complete state of work from the previous session so the next Claude session can resume without any context loss. Read this file, then proceed with "Immediate action required" below.

---

## Goal of this work

The user wanted Claude Code (the `claude` harness) running inside the sandbox to:

1. **Act autonomously without asking for permission on most operations** — file reads, writes, edits, bash commands — so the harness moves fast.
2. **Still prompt before running `sudo` or `su`** — so the user explicitly approves software installation.
3. **Never silently execute a class of genuinely dangerous commands** — credential reads, destructive disk ops, pipe-to-shell patterns.

The solution is a `~/.claude/settings.json` inside the container that Claude Code reads on startup. It is bind-mounted read-only so the harness cannot modify its own permission rules.

---

## Changes made this session

### 1. `src/claude-settings.json` (NEW FILE)

Claude Code's settings file, mounted into every container at `/home/agent/.claude/settings.json:ro`.

Key structure:
- `defaultMode: "bypassPermissions"` — no prompts for normal operations
- `ask: ["Bash(sudo *)", "Bash(su *)"]` — Claude Code pauses and shows a permission dialog before executing these; user must approve in the Claude Code UI
- `deny: [...]` — 19 patterns that are hard-blocked regardless of any other setting:
  - Credential file reads: `~/.ssh/**`, `~/.gnupg/**`, `~/.aws/**`, `~/.config/gh/**`, `~/.docker/config.json`
  - `.env` file reads: `**/.env`, `**/.env.*`
  - Dangerous bash: `pass *`, `gpg *`, `ssh *`, `scp *`, `rsync *:*`, `curl * | sh*`, `wget * | sh*`, `rm -rf / *`, `rm -rf ~ *`, `dd *`, `mkfs*`, `mount *`
- `env.CLAUDE_SANDBOX: "true"` — harness can detect it is sandboxed

**Note on `ask` field:** `deny > ask > allow` is the intended Claude Code priority chain. This has been used; if a future Claude Code version does not honour `ask`, sudo would fall through to `allow` (i.e., run silently). Easy to change to `deny` if that behaviour is observed.

### 2. `src/Dockerfile` — two additions

**a. `sudo` package + sudoers config** (added to user-creation RUN block):
```dockerfile
RUN groupadd --system docker \
  && useradd --create-home --uid 1000 --shell /usr/local/bin/env-bash agent \
  && usermod -aG docker,sudo agent \
  && printf 'agent ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/agent \
  && chmod 0440 /etc/sudoers.d/agent
```
`NOPASSWD` is intentional — the permission gate is the Claude Code `ask` prompt in the UI, not an OS-level password. Without `NOPASSWD`, a `[sudo] password:` prompt would deadlock mid-session.

**b. `.claude/` directory + settings file seed** (added before `USER agent`):
```dockerfile
RUN mkdir -p /home/agent/.claude && chown agent:agent /home/agent/.claude
COPY --chown=agent:agent src/claude-settings.json /home/agent/.claude/settings.json
```
Seeds fresh named volumes with the settings file. The CLI bind mount (see below) is the primary mechanism for existing volumes.

### 3. `bin/ai-sandbox` — two additions

**a. `SCRIPT_DIR` resolution** at the top of the script (after `SCRIPT_NAME`), symlink-safe and macOS-portable:
```bash
_script_real="$0"
while [[ -L "$_script_real" ]]; do
  _link_target="$(readlink "$_script_real")"
  if [[ "$_link_target" != /* ]]; then
    _link_target="$(dirname "$_script_real")/${_link_target}"
  fi
  _script_real="$_link_target"
done
SCRIPT_DIR="$(cd "$(dirname "$_script_real")" && pwd)"
unset _script_real _link_target
```

**b. Bind mount in `build_docker_cmd`** (after the home volume mount, before extra mounts):
```bash
local claude_settings="${SCRIPT_DIR}/../src/claude-settings.json"
if [[ -f "$claude_settings" ]]; then
  cmd+=(-v "${claude_settings}:/home/agent/.claude/settings.json:ro")
  echo "[sandbox] claude settings mounted read-only" >&2
fi
```
This ensures even containers with an existing named volume (where the Dockerfile COPY won't propagate) get the settings file. The `:ro` is enforced by Docker — even root inside the container cannot write to a `:ro` bind-mounted file.

### 4. `test/run_tests.sh` — three changes

**a. `test_extra_mounts` baseline count updated:** `v_count -eq 3` → `v_count -eq 4`
The standard set of mounts is now: workspace + sandbox.json:ro + home volume + claude-settings:ro.

**b. `test_claude_settings()` added** (11 assertions):
- Static: file exists, valid JSON, `defaultMode` is `bypassPermissions`, `ask` has sudo/su entries, sudo not in deny, deny has ≥10 entries
- Dry-run: docker command contains `:ro` mount path, stderr has `[sandbox] claude settings mounted read-only`
- Live (requires rebuilt image): file is readable inside container, write attempt is blocked

**c. `test_sudo()` added** (3 assertions, all live — require rebuilt image):
- `which sudo` resolves
- `sudo whoami` → `root`
- `sudo id -u` → `0`

Both new functions are called from `main()` between `test_home_mount_bind` and `test_e2e`.

---

## Immediate action required

**The Docker image must be rebuilt before running tests.** The `sudo` package and sudoers config are new Dockerfile additions and are not in the current image. Without a rebuild:
- All `test_sudo` assertions will fail (no `sudo` binary)
- The live `test_claude_settings` container tests may fail (`.claude/` directory may not exist in the named volume)
- The dry-run and static `test_claude_settings` assertions will pass immediately (no image needed)

Run from the project root:
```bash
make build
```

This computes a content hash of `src/Dockerfile` and rebuilds if the hash-tagged image doesn't exist. It will rebuild because the Dockerfile changed.

---

## Running tests

From the project root:
```bash
bash test/run_tests.sh
```

### Expected results after `make build`

All tests should pass. The output should end with:

```
Results: N passed, 0 failed
```

### If `test_sudo` fails

Check that the image was actually rebuilt (not just retagged):
```bash
make version        # shows current hash
docker run --rm ai-sandbox:latest which sudo
docker run --rm ai-sandbox:latest sudo --version
```

If `sudo` is not found, the old image is being used. Force a rebuild:
```bash
make rebuild
```

### If `test_claude_settings` live tests fail

The live container tests check that `/home/agent/.claude/settings.json` is readable and write-blocked. If readable fails, the bind mount may not be working — check that `src/claude-settings.json` exists and `SCRIPT_DIR` is resolving correctly:
```bash
./bin/ai-sandbox --dry-run 2>&1 | grep claude
```
Should show `[sandbox] claude settings mounted read-only` on stderr and a `-v .../src/claude-settings.json:/home/agent/.claude/settings.json:ro` in the docker command.

If write-blocked fails (write succeeded), Docker's `:ro` bind mount enforcement is not working — this would be a Docker version issue and is very unlikely.

---

## Security model — what to verify

After tests pass, confirm the complete containment picture:

| Threat | Mitigation | How to verify |
|--------|-----------|---------------|
| Harness reads host credentials | No `$HOME` mount; only `$PWD` bind-mounted | `docker run --rm ai-sandbox:latest ls /root` → permission denied |
| Claude modifies its own permission rules | `/home/agent/.claude/settings.json` is `:ro` bind mount | `test_claude_settings` write-blocked assertion |
| Claude installs software without approval | `Bash(sudo *)` in `ask` — Claude Code prompts user before executing | Manual: run `claude` harness, ask it to `apt install curl`, observe permission prompt |
| Claude runs a destructive bash command | `deny` list hard-blocks 19 patterns | Structural — enforced by Claude Code settings, not OS |
| Claude reads `.env` secrets in workspace | `deny: Read(**/.env)` | Structural — enforced by Claude Code settings |
| Named volume leaks between projects | Volume name includes project dir: `ai-sandbox-home-<project>` | `docker volume ls` — each project has its own |
| Container persists after crash | `--rm` flag; crash leaves named container; fix with `docker rm ai-sandbox-<project>` | Documented in CLAUDE.md |

The `CLAUDE_SANDBOX=true` env var is injected into every container via the settings file's `env` block. Harnesses that check this var can adjust their own behaviour (e.g., skip certain prompts they know are handled by the sandbox layer).

---

## File reference

| File | Change type | What changed |
|------|------------|-------------|
| `src/claude-settings.json` | New | Claude Code permissions file |
| `src/Dockerfile` | Modified | Added `sudo` pkg, sudoers, `.claude/` dir, settings COPY |
| `bin/ai-sandbox` | Modified | `SCRIPT_DIR` resolution, claude-settings bind mount |
| `test/run_tests.sh` | Modified | v_count 3→4, added `test_claude_settings`, added `test_sudo` |
