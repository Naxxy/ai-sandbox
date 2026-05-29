# GPT Tasks

Standalone implementation tasks for Codex/GPT behavior inside `ai-sandbox`. Each task should be executable by a fresh agent with access to this repository and the referenced files.

This document follows the workspace-builder guidance in `skills/workspace-builder/`: keep the task minimal, preserve existing structure, separate stable configuration from runtime artifacts, and include explicit validation before calling the work complete.

---

## Current State

The sandbox already applies a global Claude Code permission file to every CLI and devcontainer session:

- Source policy: `src/claude-settings.json`
- CLI mount: `bin/ai-sandbox` mounts it read-only at `/home/agent/.claude/settings.json`
- Devcontainer mount: `.devcontainer/devcontainer.json` and `.devcontainer/devcontainer.template.json` mount it read-only at the same path
- Image setup: `src/Dockerfile` creates `/home/agent/.claude` and `/home/agent/.codex`
- Tests: `test/test_cli.sh` validates the Claude settings file, dry-run mount, in-container readability, and read-only behavior; `test/test_devcontainer.sh` validates the devcontainer mount

Codex auth already exists as a separate concern:

- CLI may mount host `~/.codex/auth.json` read-only at `/home/agent/.codex/auth.json`
- Devcontainer uses shared volume `ai-sandbox-shared-codex` at `/home/agent/.codex`
- `src/claude-settings.json` denies Claude from reading `/home/agent/.codex/auth.json`

Do not replace or remove the existing Codex auth design while implementing this task.

---

## TASK: Add Sandbox-Wide Codex Global Rules

**Goal:** Create the Codex equivalent of `src/claude-settings.json` and install it into the Codex global home configuration location so any Codex/GPT instance running inside the sandbox receives the same sandbox safety intent.

**Important:** Codex does not use Claude Code's JSON permission schema. Do not copy `claude-settings.json` verbatim and assume Codex will enforce it. First verify the active Codex configuration/rules format, then map the same intent into Codex-supported files.

### Intended Policy Intent

The Codex global rules should preserve the same security posture as `src/claude-settings.json`:

- Permit normal workspace reads, writes, edits, search, and shell use inside the sandbox.
- Treat the sandbox as the security boundary, not the host.
- Do not allow the model to read credential material:
  - `~/.ssh/**`
  - `~/.gnupg/**`
  - `~/.aws/**`
  - `~/.config/gh/**`
  - `~/.docker/config.json`
  - `**/.env`
  - `**/.env.*`
  - `~/.claude/.credentials.json`
  - `/home/agent/.claude/.credentials.json`
  - `~/.codex/auth.json`
  - `/home/agent/.codex/auth.json`
- Do not allow the model to modify its own Codex global rules/config file.
- Require confirmation or deny high-risk shell operations, matching the Claude policy intent:
  - `sudo`, `su`
  - `pass`, `gpg`, `ssh`, `scp`
  - remote `rsync`
  - `curl ... | sh`, `wget ... | sh`
  - destructive disk/filesystem commands such as `rm -rf /`, `rm -rf ~`, `dd`, `mkfs`, `mount`
- Set an environment marker equivalent to `CLAUDE_SANDBOX=true`, for example `CODEX_SANDBOX=true`, if Codex supports global environment settings. If it does not, document that limitation.

### Codex Locations To Verify First

Before implementation, inspect the active Codex home directory inside the sandbox:

```bash
rg --files /home/agent/.codex
sed -n '1,160p' /home/agent/.codex/config.toml
sed -n '1,160p' /home/agent/.codex/rules/default.rules
```

At the time this task was written, Codex used:

- `/home/agent/.codex/config.toml` for global/project config
- `/home/agent/.codex/rules/default.rules` for global command approval rules

Treat those observed paths as a starting point, not a permanent contract. Check current Codex documentation or local generated files if the schema has changed.

---

## Implementation Plan

### Step A - Define Source Files

Add source-controlled Codex policy files under `src/`, mirroring the Claude settings pattern:

- `src/codex-config.toml` if Codex global config belongs in `config.toml`
- `src/codex-default.rules` if Codex global command rules belong in `rules/default.rules`

Only add the files Codex actually consumes. If current Codex supports a single config file, do not invent a second one.

The source files must not contain secrets, machine-specific paths outside `/home/agent`, or host home paths.

### Step B - Install Files In The Image

Update `src/Dockerfile` to create any required Codex directories and copy the source-controlled policy files into place.

Expected shape if both files are needed:

```dockerfile
RUN mkdir -p /home/agent/.claude /home/agent/.codex /home/agent/.codex/rules \
  && chown agent:agent /home/agent/.claude /home/agent/.codex /home/agent/.codex/rules
COPY src/codex-config.toml /home/agent/.codex/config.toml
COPY src/codex-default.rules /home/agent/.codex/rules/default.rules
RUN chmod 444 /home/agent/.codex/config.toml /home/agent/.codex/rules/default.rules
```

Preserve the existing `USER agent` invariant.

### Step C - Mount Files Read-Only In CLI Sessions

Update `bin/ai-sandbox` near the existing Claude settings mount.

Mount the Codex policy file or files read-only into `/home/agent/.codex/...` after the `/home/agent` volume and before aliases/extra mounts. Print a concise stderr message for each mounted policy file, matching the existing style:

```text
[sandbox] codex config mounted read-only
[sandbox] codex rules mounted read-only
```

Do not remove the existing `~/.codex/auth.json` read-only auth mount.

### Step D - Mount Files Read-Only In Devcontainers

Update both:

- `.devcontainer/devcontainer.json`
- `.devcontainer/devcontainer.template.json`

Add read-only bind mounts for the source-controlled Codex policy files on top of the existing `ai-sandbox-shared-codex` volume. This should use Docker's nested mount specificity in the same way Claude settings currently does.

For the template, use host-absolute paths through `${localEnv:HOME}/.ai-agents/ai-sandbox/...`, matching the existing Claude settings template mount.

Expected runtime source map:

| Path | Source |
|---|---|
| `/home/agent/.codex/**` except policy files | `ai-sandbox-shared-codex` |
| `/home/agent/.codex/config.toml` | read-only bind from `src/codex-config.toml`, if used |
| `/home/agent/.codex/rules/default.rules` | read-only bind from `src/codex-default.rules`, if used |
| `/home/agent/.codex/auth.json` | existing auth file or volume behavior; do not expose it to model-readable policy |

### Step E - Prevent Self-Modification

Ensure the Codex rules/config deny or require approval for writes/edits to their own installed paths:

- `/home/agent/.codex/config.toml`
- `/home/agent/.codex/rules/default.rules`

If Codex cannot express file-level write denies in its global rules format, rely on the read-only bind mount and document the limitation in `docs/SECURITY.md` and `docs/AGENTS_AUTH.md`.

### Step F - Tests

Update `test/test_cli.sh` with a Codex policy test similar to `test_claude_settings()`:

- Source file exists
- Source file parses with the appropriate parser (`jq` for JSON, `python`/`toml`/`grep` checks for TOML/rules)
- Rules include credential-protection entries or approved equivalent behavior
- Dry-run output includes read-only Codex policy mounts
- Stderr includes the new `[sandbox] codex ... mounted read-only` messages
- In-container policy file is readable
- In-container write to the mounted policy file fails

Update mount-count expectations in existing dry-run tests if adding new `-v` flags changes the count.

Update `test/test_devcontainer.sh`:

- Validate each Codex policy bind mount is present
- Validate each Codex policy bind mount is read-only
- Validate the existing `ai-sandbox-shared-codex` volume remains present
- Validate no bind mount exposes host `~/.codex` wholesale

### Step G - Documentation

Update:

- `docs/SECURITY.md` with the Codex global policy mount and self-modification protections
- `docs/AGENTS_AUTH.md` with the nested mount map for Codex auth volume plus policy-file read-only binds
- `docs/TUTORIAL.md` if users need to know where global Codex sandbox rules come from
- `docs/CHANGELOG.md` with a newest-first entry once implemented

---

## Validation Commands

Run these before marking the implementation complete:

```bash
jq empty src/claude-settings.json
test/test_cli.sh
test/test_devcontainer.sh
make build
./bin/ai-sandbox --dry-run codex 2>&1 | grep -E "codex (config|rules) mounted read-only"
./bin/ai-sandbox --shell -- test -r /home/agent/.codex/rules/default.rules
./bin/ai-sandbox --shell -- bash -c 'echo x > /home/agent/.codex/rules/default.rules'
```

Expected result for the final command: non-zero exit because the rules file is read-only.

If Codex uses only `/home/agent/.codex/config.toml`, replace the `default.rules` validation path with `/home/agent/.codex/config.toml`.

---

## Acceptance Criteria

- A source-controlled Codex global policy file exists under `src/`.
- Every CLI sandbox session receives the policy at the Codex global home path.
- Every devcontainer session receives the policy at the Codex global home path.
- The policy is read-only at runtime.
- The existing Codex auth design remains intact.
- Tests cover CLI and devcontainer installation paths.
- Documentation explains the nested mount behavior and the Codex/Claude policy split.
