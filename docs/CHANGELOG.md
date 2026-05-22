# AI Agent Sandbox — Completed Steps

> All steps below have been implemented and validated. Moved from `IMPLEMENTATION_PLAN.md` on 2026-05-13.
> See `docs/SCRATCHPAD.md` for bugs fixed and key decisions made during implementation.

---

## Pi coding agent harness *(2026-05-13)*

`pi` (`@earendil-works/pi-coding-agent`) is now baked into the image and registered as a harness.

**`src/Dockerfile`** — added before `USER agent`:
```dockerfile
RUN npm install -g @earendil-works/pi-coding-agent
```
Installing as root puts the binary in the system npm prefix (`/usr/local/bin/pi`), so it is available to the `agent` user and is not affected by the `/home/agent` named volume.

**`.ai-sandbox/sandbox.json`** — added harness entry:
```json
"pi": { "command": "pi" }
```

**Usage:**
```bash
# launch pi as the default harness for a run
ai-sandbox pi

# drop into a shell and run pi manually
ai-sandbox --shell
pi
```

**Validation** (after `make build`):
```bash
docker run --rm ai-sandbox:latest pi --version
```

---

## Config Enhancements *(2026-05-13)*

### `sandbox.json` pretty formatting

`sandbox.json` is normalised to canonical 2-space jq formatting (no alignment padding). The test helper `with_modified_config` in `test/run_tests.sh` now writes `indent=2` so the file stays readable during test runs.

### `mergeMode` key in `sandbox.local.json`

`sandbox.local.json` supports a top-level `"mergeMode"` key that controls how it is merged with `sandbox.json`:

| Value | Behaviour |
|---|---|
| `"merge"` (default) | Deep merge — `jq '.[0] * .[1]'`. Local wins for all conflicts; arrays in local **replace** base arrays. |
| `"append"` | Deep merge — local scalar values win; arrays are **concatenated** (base + local). Useful for adding extra mounts without repeating the base list. |
| `"replace"` | `sandbox.local.json` is used as the sole config; `sandbox.json` is ignored entirely. |

Unknown values exit 1 with an error message.

**Implementation note:** jq 1.8.x has a bug where recursive multi-arg functions fail when their arguments are input path expressions (`.[0]`, `.[1]`). Fixed by binding to variables first: `.[0] as $base | .[1] as $local | deepmerge_append($base; $local)`.

**Test coverage (`test/run_tests.sh`):**
- `test_merge_mode()`: append concatenates `extraMounts`, replace isolates from base, explicit merge still works, unknown mode → exit 1

---

## Repository Layout (Implemented)

```
ai-sandbox/
├── src/Dockerfile
├── Makefile
├── bin/ai-sandbox                # executable CLI script
├── .ai-sandbox/                  # example workspace config
│   ├── sandbox.json
│   ├── env
│   └── secrets.env               # gitignored
├── CLAUDE.md
└── docs/
    ├── PRD.md
    ├── IMPLEMENTATION_PLAN.md
    ├── CHANGELOG.md
    └── SCRATCHPAD.md
```

---

## Phase 1 — Core Infrastructure

### Step 1.1 — Write the Dockerfile ✓

- Base image: `debian:bookworm-slim` (Chainguard Wolfi had package gaps)
- Non-root user `agent` (UID 1000) via `useradd --create-home`
- Installed: `bash`, `git`, `curl`, `jq`, `ripgrep`, `fd-find` (symlinked to `/usr/local/bin/fd`), `python3`, `pip`, `node`, `npm`
- `WORKDIR /workspace`
- No host files copied into image

**Validation commands:**
```bash
docker build -t ai-sandbox:dev .
docker run --rm ai-sandbox:dev whoami          # → agent
docker run --rm ai-sandbox:dev bash -c "jq --version && git --version && node --version"
docker run --rm ai-sandbox:dev id              # → uid=1000(agent)
```

---

### Step 1.2 — Build & Tag the Image ✓

- `Makefile` with `make build` → tags `ai-sandbox:latest` and `ai-sandbox:$(VERSION)`
- `ARG VERSION` in Dockerfile

**Validation commands:**
```bash
docker images ai-sandbox
time docker run --rm ai-sandbox:latest bash -c "exit 0"   # < 3s after first pull
```

---

### Step 1.3 — Create the `ai-sandbox` CLI Script (skeleton) ✓

- `bin/ai-sandbox`, `chmod +x`, shebang `#!/usr/bin/env bash`
- No `set -euo pipefail` — explicit error checking throughout
- Skeleton evolved into full CLI

**Validation commands:**
```bash
./bin/ai-sandbox                              # exits 1 with readable message
```

---

### Step 1.4 — Implement Config Loading (`sandbox.json`) ✓

- `load_config()` walks up from `$PWD` to find `.ai-sandbox/sandbox.json`
- `jq` parses; fails clearly on missing file or invalid JSON
- Extracts: `defaultHarness`, `defaultModel`, `sandbox.workspacePath`, `sandbox.readonly`, `sandbox.network`

**Validation commands:**
```bash
cd /tmp && ai-sandbox                          # → "No .ai-sandbox/sandbox.json found"
# Invalid JSON → "Invalid JSON in sandbox.json"
cd <repo> && ai-sandbox --dry-run              # → prints resolved harness + model
```

---

### Step 1.5 — Implement `docker run` Logic ✓

- `build_docker_cmd()` assembles the full `docker run` invocation
- Mounts: `$PWD` → `/workspace` (`:ro`/`:rw`), named volume `ai-sandbox-home` → `/home/agent`
- Env vars via temp `--env-file` (deleted on exit via `trap cleanup EXIT`)
- `--rm` by default; `--interactive --tty` when stdin is a TTY
- `--` args **replace** the container CMD (stored in `DOCKER_CMD_DEFAULT`)

**Validation commands:**
```bash
ai-sandbox --shell                             # opens bash at /workspace
ai-sandbox --shell -- bash -c "ls /workspace"  # lists PWD contents
ai-sandbox --shell -- whoami                   # → agent
```

---

## Phase 2 — Model & Provider Abstraction

### Step 2.1 — Provider-to-Env-Var Mapping ✓

`resolve_model_env()` maps model config to env vars:

| Provider     | Env vars injected                                    |
|-------------|------------------------------------------------------|
| `ollama`    | `OLLAMA_BASE_URL`, `MODEL`                          |
| `openrouter`| `OPENROUTER_API_KEY`, `OPENAI_BASE_URL`, `MODEL`   |
| `openai`    | `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_BASE_URL` (if `baseUrl` set) |
| `anthropic` | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`             |
| `google`    | `GOOGLE_API_KEY`, `GOOGLE_MODEL`                   |

API keys read from host environment, not config files. Vars written to temp file via `_emit_env()`.

**Validation commands:**
```bash
ai-sandbox --model local-qwen --dry-run        # → OLLAMA_BASE_URL and MODEL printed
ai-sandbox --model openrouter-free --dry-run   # → OPENAI_BASE_URL and MODEL printed
ai-sandbox --model nonexistent --dry-run       # → "Model 'nonexistent' not found"
```

---

### Step 2.2 — Env File Injection (`.ai-sandbox/env` + `secrets.env`) ✓

- Loads `.ai-sandbox/env` if present
- Loads `.ai-sandbox/secrets.env` if present (no error if absent)
- Merges both into temp env file alongside model env vars
- `secrets.env` values bypass `_emit_env()` — never appear in stdout or `--dry-run` output

**Validation commands:**
```bash
ai-sandbox --shell -- bash -c "echo MY_VAR=\$MY_VAR"       # → MY_VAR=hello
ai-sandbox --shell -- bash -c "echo SECRET_KEY=\$SECRET_KEY" # → SECRET_KEY=hunter2
ai-sandbox --dry-run 2>&1 | grep -i hunter2                 # → no output
```

---

## Phase 3 — UX & CLI Flags

### Step 3.1 — Full Flag Implementation ✓

| Flag              | Behavior                                              |
|------------------|-------------------------------------------------------|
| `<harness>`      | Positional arg: override default harness             |
| `--model <key>`  | Override default model from config                   |
| `--readonly`     | Mount `/workspace` as `:ro`                          |
| `--no-network`   | Add `--network none` to docker run                   |
| `--shell`        | Override CMD with `bash`                             |
| `--dry-run`      | Print resolved env vars + docker command, do not execute |
| `--help` / `-h`  | Print usage and exit 0                               |

Case arms sorted lexicographically in script.

**Validation commands:**
```bash
ai-sandbox --dry-run                           # prints full docker run command
ai-sandbox aider --dry-run                     # CMD is "aider"
ai-sandbox --readonly --dry-run                # /workspace mount ends with :ro
ai-sandbox --no-network --dry-run              # --network none present
ai-sandbox --shell --dry-run                   # CMD is bash
```

---

### Step 3.2 — Help Output & Input Validation ✓

- `show_help()` prints to stdout (not stderr); exits 0
- Validates positional harness arg exists in `harnesses` map
- Validates `--model` arg exists in `models` map
- `warn_if_dangerous_mount()` warns when `$PWD == $HOME` or `$PWD == /`

**Validation commands:**
```bash
ai-sandbox --help | grep -E "\-\-model|\-\-readonly|\-\-no-network|\-\-shell|\-\-dry-run"
ai-sandbox unknown-harness   # → "Harness 'unknown-harness' not defined in sandbox.json"
ai-sandbox --model ghost     # → "Model 'ghost-model' not defined in sandbox.json"
cd $HOME && ai-sandbox --dry-run  # → warning about home/root directory
```

---

## Phase 4 — Security Hardening

### Step 4.1 — Read-Only Mode ✓

- `--readonly` flag OR `sandbox.readonly: true` → appends `:ro` to `/workspace` mount
- Prints `[sandbox] workspace mounted read-only` to stderr

**Validation commands:**
```bash
ai-sandbox --readonly --shell -- bash -c "touch /workspace/test_rw_file"  # → read-only error
ai-sandbox --shell -- bash -c "touch /workspace/test_rw_file && echo OK"  # → OK
```

---

### Step 4.2 — No-Network Mode ✓

- `--no-network` flag OR `sandbox.network: false` → adds `--network none` to `docker run`
- Prints `[sandbox] network disabled` to stderr

**Validation commands:**
```bash
ai-sandbox --no-network --shell -- bash -c "curl -s https://example.com --max-time 3 || echo BLOCKED"  # → BLOCKED
ai-sandbox --shell -- bash -c "curl -s https://example.com --max-time 3 | head -c 50"                  # → HTML
```

---

### Step 4.3 — Kernel Security Warning ✓

- Every invocation prints to stderr:
  ```
  WARNING: Container sandboxing depends on host kernel security.
  Ensure your system is patched against recent vulnerabilities (e.g. Copy Fail / CVE-2026-31431).
  Kernel: <uname -r output>
  ```
- On Linux: if kernel < 6.6, emits additional `SECURITY WARNING: kernel may be unpatched`
- `SECURITY.md` documents the Copy Fail limitation

**Validation commands:**
```bash
ai-sandbox --dry-run 2>&1 | grep -i "WARNING"              # → warning line appears
KERNEL_OVERRIDE="5.4.0" ai-sandbox --dry-run 2>&1 | grep -i "unpatched"  # → additional warning
cat SECURITY.md | grep -i "copy fail"                       # → documented
```

---

## Phase 5 — Stretch Goals (Completed Stubs)

### Step 5.1 — VS Code Dev Container Integration ✓

- `.devcontainer/devcontainer.json` created, pointing at `src/Dockerfile` with build context `..`
- `remoteUser: "agent"` — container runs as UID 1000, never root
- `workspaceMount` overrides default VS Code mount: `source=${localWorkspaceFolder},target=/workspace,type=bind`
- `workspaceFolder: /workspace` — terminal and extensions open here
- `mounts`: named volume `ai-sandbox-home` → `/home/agent` (persists across rebuilds; no host bind)
- No `$HOME`, `~/.ssh`, `~/.aws`, or any host path outside the workspace is mounted
- Extensions auto-installed: `continue.continue`, `rooveterinaryinc.roo-cline`
- Static validation: `test/test_devcontainer.sh` (13 checks — JSON validity, security invariants, extension presence, path resolution)

**Manual validation (VS Code):**
```
1. Open repo in VS Code
2. Command Palette → "Reopen in Container"
3. Terminal opens as user `agent`
4. Continue and Roo Code extensions are installed
5. `ls /workspace` shows repo contents
6. `ls $HOME/../..` does NOT show host home structure
```

---

### Step 5.2 — Plugin System (stub) ✓

- `load_plugins()` stub: logs `[sandbox] plugin support not yet implemented` if `plugins` array is non-empty in config

**Validation commands:**
```bash
ai-sandbox --dry-run 2>&1 | grep -i "plugin"  # → warning, no crash
```

---

### Step 5.3 — Sandbox Profiles (stub) ✓

- `apply_profile()` stub: parses `sandboxProfiles` map from config; `--profile <name>` merges `network`/`readonly` overrides
- Fixed: `false // empty` jq bug — uses `if .field != null then (.field | tostring) else empty end`

**Validation commands:**
```bash
ai-sandbox --profile strict --dry-run  # → --network none and :ro both present
```

---

## End-to-End Acceptance Test — PASSED ✓

All 7 checks passing (validated 2026-05-05):

```bash
# 1. Basic launch
ai-sandbox --shell -- bash -c "pwd && whoami"
# → /workspace, agent

# 2. Model override
ai-sandbox --model local-qwen --dry-run | grep "MODEL=qwen3.5:4b"
# → match found

# 3. Readonly enforcement
ai-sandbox --readonly --shell -- bash -c "touch /workspace/x 2>&1 || echo BLOCKED"
# → BLOCKED

# 4. Network isolation
ai-sandbox --no-network --shell -- bash -c "curl -s https://example.com --max-time 2 2>&1 || echo BLOCKED"
# → BLOCKED

# 5. No host filesystem leakage
ai-sandbox --shell -- bash -c "ls /root 2>&1; ls /home/$(whoami) 2>&1 | wc -l"
# → errors or 0 lines

# 6. Kernel warning present
ai-sandbox --dry-run 2>&1 | grep -c "WARNING"
# → >= 1

# 7. Help works
ai-sandbox --help; echo "exit=$?"
# → exit=0
```

---

## Phase 6 — Usability & Developer Experience

### Step 6.1 — Extra Mounts (CLI + devcontainer) ✓ *(implemented 2026-05-13)*

**Problem:** Users need to selectively expose host paths (e.g. `~/.claude/`) into the sandbox without opening the entire host `$HOME`.

**CLI changes (`bin/ai-sandbox`):**
- `build_docker_cmd()` reads `sandbox.extraMounts[]` from config; validates `host` and `container` fields are present
- Expands `~` in `host` via `${host/#\~/$HOME}` (not shell glob)
- Defaults `readonly` to `true` when omitted (fail-safe)
- Appends `-v host:container:ro` (or `:rw`) to the `docker run` command for each entry
- Extra mount `-v` flags appear in `--dry-run` output as part of the docker command line
- `warn_if_dangerous_mount()` extended: warns if any `extraMounts[].host` resolves to `$HOME` or `/`

**devcontainer changes (`.devcontainer/devcontainer.json`):**
- Added `${localEnv:HOME}/.claude` → `/home/agent/.claude` (readonly) to `mounts` array, using VS Code's `${localEnv:HOME}` expansion so the host home subdirectory is visible in the dev container

**Test coverage (`test/run_tests.sh`):**
- `test_extra_mounts()`: empty array, `readonly:true` → `:ro`, omitted `readonly` → `:ro`, `~` expansion, missing `host` → exit 1, missing `container` → exit 1, home path → warning, absent key → backward-compatible
- `test_config_precedence()`: `sandbox.local.json` overrides model, inherits harnesses, adds `extraMounts`, invalid JSON → exit 1

**Test coverage (`test/test_devcontainer.sh`):**
- `test_no_host_home_in_mounts_array()`: updated to allow subdirectory `${localEnv:HOME}/subdir` mounts; still blocks bare home, `.ssh`, `.aws`
- `test_extra_mount_claude_devcontainer()`: verifies `~/.claude` entry present with `localEnv:HOME` expansion

**Security invariant maintained:** Extra mounts are explicit and per-project. The CLI never auto-discovers or auto-mounts any host path not listed in `extraMounts`.

**Validation commands:**
```bash
# Add entry to sandbox.json extraMounts, then:
./bin/ai-sandbox --dry-run
# Expected: dry-run output includes -v $HOME/.claude:/home/agent/.claude:ro

./bin/ai-sandbox --shell -- ls /home/agent/.claude
# Expected: contents of host ~/.claude appear inside container

bash test/test_devcontainer.sh
# Expected: 18 passed, 0 failed

bash test/run_tests.sh
# Expected: all extra-mounts and config-precedence tests pass
```

---

### Step 6.2 — Sandbox Home Introspection (bind mount mode) ✓ *(implemented 2026-05-13)*

**Problem:** The `/home/agent` named Docker volume is opaque — no easy way to browse its contents without `docker` CLI commands.

**CLI changes (`bin/ai-sandbox`):**
- `load_config()` reads `CFG_HOME_MOUNT` from `sandbox.homeMount` (default `"volume"`)
- `build_docker_cmd()` branches on the value:
  - `"volume"` (default) — named Docker volume `ai-sandbox-home-<project>` → `/home/agent` (unchanged behavior)
  - `"bind"` — bind-mounts `<project-root>/.ai-sandbox/home/` → `/home/agent:rw`; creates the directory if absent; appends `.ai-sandbox/home/` to `.gitignore` on first creation if that file exists
- The resolved bind path appears in `--dry-run` output (it is part of the `-v` flag in `DOCKER_CMD`)

**devcontainer note:** When switching a project to `homeMount: "bind"`, replace the named-volume `mounts` entry in `.devcontainer/devcontainer.json` with:
```
"source=${localWorkspaceFolder}/.ai-sandbox/home,target=/home/agent,type=bind"
```
This repo's `devcontainer.json` keeps the named volume (default mode).

**Trade-offs:**
- Volume mode: more isolated; opaque on the host
- Bind mode: home files directly browsable/editable on the host; only `.ai-sandbox/home/` is exposed, not the host `$HOME`

**Test coverage (`test/run_tests.sh`):**
- `test_home_mount_bind()`: bind mode produces `:rw` bind mount, directory created automatically, `.gitignore` entry appended, volume mode uses named volume, absent key defaults to volume

**Validation:**
```bash
# Add "homeMount": "bind" to sandbox.json, then:
./bin/ai-sandbox --shell -- bash -c "echo hello > ~/probe.txt"
ls .ai-sandbox/home/probe.txt   # must exist on host
cat .ai-sandbox/home/probe.txt  # must print "hello"
```

---

### Step 6.3 — Core Tooling in Container Image ✓ *(implemented 2026-05-13)*

**Problem:** The image lacked basic interactive editing and inspection tools for `--shell` sessions.

**Dockerfile changes (`src/Dockerfile`):**
All tools added to the single `apt-get install` layer, alphabetically sorted:

| Tool | Package |
|---|---|
| `file` | `file` |
| `htop` | `htop` |
| `less` | `less` |
| `tree` | `tree` |
| `vim` | `vim` |
| `wget` | `wget` |

(All were present before this session — confirmed in `debian:sid-slim`.)

**Validation:**
```bash
make build
docker run --rm ai-sandbox:latest vim --version | head -1
docker run --rm ai-sandbox:latest tree --version
docker run --rm ai-sandbox:latest htop --version
docker run --rm ai-sandbox:latest file --version | head -1
docker run --rm ai-sandbox:latest wget --version | head -1
```

---

### Step 6.4 — Persistent VS Code Extension State (devcontainer) ✓ *(implemented 2026-05-13)*

**Problem:** Extensions not listed in `customizations.vscode.extensions` are never auto-installed on a fresh volume, and their binaries are lost on `docker volume rm`.

**Changes:**
- `customizations.vscode.extensions` in `.devcontainer/devcontainer.json` lists all four extensions: `anthropic.claude-code`, `continue.continue`, `openai.chatgpt`, `rooveterinaryinc.roo-cline`
- Named volume at `target=/home/agent` covers `/home/agent/.vscode-server/extensions/` — extension binaries persist across container restarts and are re-installed from the list on a fresh volume

**Test coverage (`test/test_devcontainer.sh`):**
- `test_extension_claude_code()`: verifies `anthropic.claude-code` listed
- `test_extension_chatgpt()`: verifies `openai.chatgpt` listed
- `test_vscode_server_covered()`: verifies named volume at `/home/agent` covers `.vscode-server` cache

**Validation:**
```bash
bash test/test_devcontainer.sh
# Expected: 19 passed, 0 failed

# Manual (VS Code):
# 1. docker volume rm ai-sandbox-home-<project>
# 2. Reopen in Container
# 3. code --list-extensions  →  all four extensions present without manual install
```

---

## Phase 7 — Config Architecture

### Step 7.1 — sandbox.json / sandbox.local.json Merge System ✓ *(implemented 2026-05-13)*

`load_config()` deep-merges `sandbox.local.json` on top of `sandbox.json` at load time using `jq -s '.[0] * .[1]'`. Only keys that differ from the shared base need to be in `sandbox.local.json`. Arrays (e.g. `extraMounts`) are replaced rather than concatenated when overridden.

Config file roles:

| File | Scope | Committed? |
|---|---|---|
| `sandbox.json` | Shared across all workspaces (symlinked or copied) | Yes — shared repo |
| `sandbox.local.json` | Workspace-specific overrides only | Yes — per workspace |

### Step 7.1 — Read-Only `sandbox.json` Enforcement ✓ *(implemented 2026-05-13)*

**Problem:** `sandbox.json` is the shared source of truth. Any harness running with a read-write workspace mount could silently overwrite it (or its symlink target), corrupting the config for every other project sharing that file.

**Implementation (`bin/ai-sandbox`):**

After the workspace bind-mount is added to the `docker run` command, `build_docker_cmd()` checks whether `CONFIG_PROJECT_ROOT == $PWD` (i.e., whether `.ai-sandbox/sandbox.json` is accessible through the workspace mount). When it is, a second, more-specific bind-mount is layered on top:

```
-v /path/to/.ai-sandbox/sandbox.json:/workspace/.ai-sandbox/sandbox.json:ro
```

Docker's overlay semantics give the more-specific mount precedence: the file is read-only inside the container while the rest of the workspace remains writable.

**Opt-out (`allowSharedConfigWrite`):**

Setting `"allowSharedConfigWrite": true` in `sandbox.local.json` (or the merged config) skips the `:ro` overlay for that workspace. The `ai-sandbox` development workspace uses this flag because it is the canonical place to edit `sandbox.json`.

```json
{
  "mergeMode": "append",
  "allowSharedConfigWrite": true,
  ...
}
```

**When protection is skipped automatically:**

If `$PWD` is a subdirectory of `CONFIG_PROJECT_ROOT` (e.g. running `ai-sandbox` from inside a project subdirectory), `.ai-sandbox/` is not inside the mounted workspace, so the container cannot reach `sandbox.json` at all — no overlay is needed.

**Stderr message:**

```
[sandbox] sandbox.json protected read-only
```

**Test coverage (`test/run_tests.sh`):**
- `test_config_readonly()`: default protection active; `allowSharedConfigWrite:true` suppresses it
- `test_extra_mounts()`: updated expected `-v` flag count from 2 → 3 (workspace + `sandbox.json:ro` + home volume)

**Validation:**
```bash
./bin/ai-sandbox --dry-run 2>&1 | grep "sandbox\.json"
# Expected (no allowSharedConfigWrite): .../sandbox.json:.../sandbox.json:ro

# With allowSharedConfigWrite: true:
# Expected: sandbox.json not in the docker command at all
```

---

## Cross-Cutting Concerns

### Secret Safety Checklist

| Check | How to verify |
|-------|--------------|
| `secrets.env` is gitignored | `git check-ignore .ai-sandbox/secrets.env` → path printed |
| Secrets not in `--dry-run` stdout | `ai-sandbox --dry-run 2>&1` → grep for known secret value |
| Temp env file deleted on exit | `ls /tmp/ai-sandbox-*` → no files after run |

### Mount Safety Checklist

| Check | How to verify |
|-------|--------------|
| No `$HOME` mount | `docker inspect <cid>` → Mounts array has only `/workspace` + named volume |
| No `~/.ssh` mount | Same inspect |
| Named volume for `/home/agent` | `docker volume ls` → `ai-sandbox-home` listed |
