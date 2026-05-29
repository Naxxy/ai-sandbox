# ai-sandbox Tutorial

`ai-sandbox` runs AI coding agents inside a Docker container, mounting only your current project directory. Your home directory, SSH keys, and credentials are never exposed.

---

## Prerequisites

- Docker Desktop (macOS) or Docker Engine (Linux), running
- The `ai-sandbox:latest` image built: `make build` from the project root
- `bin/ai-sandbox` on your `$PATH`, or invoked directly as `./bin/ai-sandbox`

---

## 1. Setting up a project

Every project you want to run agents in needs a config directory:

```
your-project/
└── .ai-sandbox/
    ├── sandbox.json        # required — shared base config, commit to version control
    ├── sandbox.local.json  # optional — per-machine overrides (see section 1.1)
    ├── env                 # optional — non-secret env vars, committed
    └── secrets.env         # optional — API keys, gitignored
```

### Minimal `sandbox.json`

```json
{
  "defaultHarness": "shell",
  "defaultModel": "local-qwen",
  "harnesses": {
    "shell": { "command": "bash" }
  },
  "models": {
    "local-qwen": {
      "provider": "ollama",
      "model": "qwen2.5-coder:7b",
      "baseUrl": "http://host.docker.internal:11434"
    }
  },
  "sandbox": {
    "workspacePath": "/workspace",
    "readonly": false,
    "network": true
  }
}
```

Run `ai-sandbox` from any directory inside the project. It walks up the tree to find `.ai-sandbox/sandbox.json`.

### `sandbox.workspacePath` — where the workspace is mounted inside the container

`workspacePath` controls the path inside the container where `$PWD` is bind-mounted. The default is `/workspace`.

For workspaces that use Claude Code skills via relative symlinks (see `docs/SKILLS_LINKING.md`), set `workspacePath` to the depth-matched path:

```json
"sandbox": {
  "workspacePath": "/home/agent/projects/ai/<workspace-name>"
}
```

This ensures the symlinks in `.claude/skills/` resolve correctly inside the container. Also add an `extraMount` for the XDG skills directory so the symlink targets are present:

```json
"sandbox": {
  "workspacePath": "/home/agent/projects/ai/<workspace-name>",
  "extraMounts": [
    { "host": "~/.local/share/ai-agents", "container": "/home/agent/.local/share/ai-agents", "readonly": false }
  ]
}
```

**Prerequisite:** Clone each skill repo once per machine into `~/.local/share/ai-agents/skills/<skill-name>` before launching the container. See `docs/SKILLS_LINKING.md` for the full setup procedure.

---

### 1.1 Per-machine overrides — `sandbox.local.json`

`sandbox.json` is the **shared base**: commit it, keep it identical across machines. `sandbox.local.json` lets each machine extend or override the base without touching the shared file.

When both files are present, `ai-sandbox` merges them at launch. The `mergeMode` key in `sandbox.local.json` controls exactly how that merge works.

#### Merge modes

| `mergeMode` | Behaviour |
|---|---|
| `"merge"` **(default)** | Deep merge — local wins for any conflicting key; arrays in local **replace** matching base arrays. |
| `"append"` | Deep merge — local wins for scalar conflicts; arrays are **concatenated** (base entries first, then local). |
| `"replace"` | `sandbox.local.json` is the **entire** config — `sandbox.json` is ignored. All required fields must be present. |

The default is `"merge"`, which means local values override the base but never silently discard base array entries without you explicitly replacing them.

#### Starter template

Create `.ai-sandbox/sandbox.local.json` and add only what differs from the base. The `mergeMode` key is optional (defaults to `"merge"`), but stating it explicitly makes the intent clear:

```json
{
  "mergeMode": "merge"
}
```

#### Example — override the default model on a machine without Ollama

`sandbox.local.json`:
```json
{
  "mergeMode": "merge",
  "defaultModel": "openrouter-free"
}
```

Everything else (harnesses, sandbox settings, other models) is inherited from `sandbox.json`.

#### Example — add extra mounts without repeating the base list

`"merge"` mode replaces the entire `extraMounts` array. If `sandbox.json` defines shared mounts and you want to add machine-specific ones on top, use `"append"` instead:

`sandbox.json` (shared, committed):
```json
"sandbox": {
  "extraMounts": [
    { "host": "~/.gitconfig", "container": "/home/agent/.gitconfig", "readonly": true }
  ]
}
```

`sandbox.local.json` (machine-specific):
```json
{
  "mergeMode": "append",
  "sandbox": {
    "extraMounts": [
      { "host": "~/.claude", "container": "/home/agent/.claude", "readonly": true }
    ]
  }
}
```

Result: the container gets **both** mounts — the shared `.gitconfig` from the base and the local `.claude` from the override. Without `"append"`, only the local `.claude` mount would be active.

#### Example — replace mode (air-gapped or fully custom machine)

Use `"replace"` when a machine needs a config that shares nothing with the base — for example, a fully offline machine:

```json
{
  "mergeMode": "replace",
  "defaultHarness": "shell",
  "defaultModel": "local-qwen",
  "harnesses": {
    "shell": { "command": "bash" }
  },
  "models": {
    "local-qwen": {
      "provider": "ollama",
      "model": "qwen2.5-coder:7b",
      "baseUrl": "http://host.docker.internal:11434"
    }
  },
  "sandbox": {
    "workspacePath": "/workspace",
    "readonly": false,
    "network": true
  }
}
```

> **Note:** in `replace` mode the base `sandbox.json` is completely ignored. You must include all required fields (`defaultHarness`, `defaultModel`, `harnesses`, `models`, `sandbox`).

#### Verifying the resolved config

`--dry-run` shows what merging produced — which model and env vars are active — without running anything:

```bash
ai-sandbox --dry-run
```

Use this any time you're unsure whether your `sandbox.local.json` is being applied correctly.

---

## 2. Basic usage

```bash
cd your-project

# Launch the default harness with the default model
ai-sandbox

# Launch a specific harness
ai-sandbox aider

# Override the model for this run
ai-sandbox --model openrouter-free
```

The container mounts `$PWD` at the path configured by `sandbox.workspacePath` (default `/workspace`). Whatever you can see in your terminal you can see inside the container — nothing more.

---

## 3. Harnesses

A harness is any command the container can run. Add as many as you like to `sandbox.json`:

```json
"harnesses": {
  "aider":    { "command": "aider" },
  "opencode": { "command": "opencode" },
  "claude":   { "command": "claude" },
  "shell":    { "command": "bash" }
}
```

Switch by passing the harness name as the first argument:

```bash
ai-sandbox aider
ai-sandbox opencode
```

If the harness isn't installed in the image, the container will exit with a "command not found" error. Install it in `src/Dockerfile` and rebuild.

---

## 4. Models and providers

Supported providers and the env vars they inject:

| Provider | Vars injected |
|---|---|
| `ollama` | `OLLAMA_BASE_URL`, `MODEL` |
| `openrouter` | `OPENROUTER_API_KEY`, `OPENAI_BASE_URL`, `MODEL` |
| `openai` | `OPENAI_API_KEY`, `OPENAI_MODEL` |
| `anthropic` | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` |
| `google` | `GOOGLE_API_KEY`, `GOOGLE_MODEL` |

### Ollama (local)

```json
"local-qwen": {
  "provider": "ollama",
  "model": "qwen2.5-coder:7b",
  "baseUrl": "http://host.docker.internal:11434"
}
```

`host.docker.internal` resolves to your host machine inside Docker Desktop. On Linux, use your host's LAN IP instead.

### OpenRouter

```json
"openrouter-free": {
  "provider": "openrouter",
  "model": "mistralai/mistral-7b-instruct:free"
}
```

Put your key in `.ai-sandbox/secrets.env`:

```
OPENROUTER_API_KEY=sk-or-...
```

### Anthropic

```json
"claude-sonnet": {
  "provider": "anthropic",
  "model": "claude-sonnet-4-6"
}
```

```
# .ai-sandbox/secrets.env
ANTHROPIC_API_KEY=sk-ant-...
```

API keys are read from your **host environment** at launch time (or from `secrets.env`). They are never baked into the image.

---

## 5. Environment variables

### Non-secret vars — `.ai-sandbox/env`

```
# .ai-sandbox/env  (committed to git)
EDITOR=vim
AIDER_DARK_MODE=true
```

These are injected into the container and visible in `--dry-run` output.

### Secret vars — `.ai-sandbox/secrets.env`

```
# .ai-sandbox/secrets.env  (gitignored — never commit this)
ANTHROPIC_API_KEY=sk-ant-...
OPENROUTER_API_KEY=sk-or-...
```

Secrets are injected into the container but are **never printed** to stdout, even with `--dry-run`.

---

## 6. Security flags

### Read-only workspace

```bash
ai-sandbox --readonly
```

The container can read your project but cannot write to it. Useful for code review or analysis runs where you don't want the agent modifying files.

You can also make this the default in `sandbox.json`:

```json
"sandbox": { "readonly": true }
```

### Disable network

```bash
ai-sandbox --no-network
```

Cuts all outbound and inbound network access for the container (`--network none`). The agent can still read and write `/workspace`. Use this when you want the agent to work purely with local files and no API calls.

You can also make this the default:

```json
"sandbox": { "network": false }
```

### Combining flags

```bash
ai-sandbox --readonly --no-network aider
```

---

## 7. Sandbox profiles

Profiles let you define named combinations of security settings:

```json
"sandboxProfiles": {
  "strict": { "network": false, "readonly": true },
  "offline": { "network": false }
}
```

Apply with `--profile`:

```bash
ai-sandbox --profile strict
ai-sandbox --profile offline --model local-qwen
```

Profile settings are applied before CLI flags, so `--profile strict --no-network` is valid (redundant, but not an error).

---

## 8. Debugging

### Open a shell in the container

```bash
ai-sandbox --shell
```

This drops you into `bash` at `/workspace` as user `agent`. Useful for checking what's installed, what env vars are set, or whether your config resolves correctly.

### Pass a one-shot command

```bash
ai-sandbox --shell -- whoami
ai-sandbox --shell -- bash -c "env | grep MODEL"
```

Arguments after `--` replace the container's default command entirely.

### Inspect the resolved docker command without running it

```bash
ai-sandbox --dry-run
ai-sandbox --model openrouter-free --readonly --dry-run
```

Prints the env vars that will be injected (excluding secrets) and the full `docker run` command. Nothing is executed.

---

## 9. Persistent agent home

The container's `/home/agent` directory is backed by a per-project Docker named volume (`ai-sandbox-home-<project>`). Tool installs, caches, and agent configurations survive across runs without touching your host home directory.

To reset it:

```bash
docker volume rm ai-sandbox-home-<project>
```

Replace `<project>` with the basename of your project directory (e.g. `ai-sandbox-home-my-project`).

---

## 10. VS Code Dev Container

The repo ships with `.devcontainer/devcontainer.json`, which lets VS Code open your project inside the sandbox container. This is an alternative to the CLI: instead of launching a harness from your host terminal, VS Code itself moves inside the container and GUI-based agents (Roo Code, Continue) run there.

### What you get

| Surface | Behaviour |
|---|---|
| VS Code integrated terminal | Opens as `agent` inside the container at `/workspace` |
| Roo Code extension | Installed automatically; runs inside the container |
| Continue extension | Installed automatically; runs inside the container |
| File access | Only the project you opened in VS Code (`/workspace`); your host home, `~/.ssh`, `~/.aws` are not mounted |
| Auth persistence | Claude and Codex auth live in shared named volumes (`ai-sandbox-shared-claude`, `ai-sandbox-shared-codex`) shared across all workspaces — log in once per service, persists across rebuilds |

### Prerequisites

- Docker Desktop (macOS) or Docker Engine (Linux), running
- The `ai-sandbox:latest` image built: run `make build` from the ai-sandbox repo
- [VS Code Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) installed

### Opening the ai-sandbox project itself in a container

The `.devcontainer/devcontainer.json` in this repo points at `src/Dockerfile` and builds the image from source. To use it:

1. Open the `ai-sandbox` folder in VS Code
2. VS Code will show a notification: **"Reopen in Container"** — click it. Or open the Command Palette (`⌘⇧P` / `Ctrl⇧P`) and run **Dev Containers: Reopen in Container**
3. VS Code rebuilds the image and reconnects inside the container

### Using the dev container in another project

For a project you want to sandbox, copy `.devcontainer/devcontainer.template.json` from this repo as `.devcontainer/devcontainer.json` in your project:

```
your-project/
└── .devcontainer/
    └── devcontainer.json
```

The template uses `${localWorkspaceFolderBasename}` to name the per-workspace home volume automatically, and shares auth volumes across all workspaces:

```json
{
  "name": "ai-sandbox",
  "runArgs": ["--name", "ai-sandbox-${localWorkspaceFolderBasename}"],
  "image": "ai-sandbox:latest",
  "remoteUser": "agent",
  "workspaceMount": "source=${localWorkspaceFolder},target=/home/agent/projects/ai/${localWorkspaceFolderBasename},type=bind",
  "workspaceFolder": "/home/agent/projects/ai/${localWorkspaceFolderBasename}",
  "mounts": [
    "source=${localWorkspaceFolderBasename}-devcontainer-home,target=/home/agent,type=volume",
    "source=ai-sandbox-shared-claude,target=/home/agent/.claude,type=volume",
    "source=ai-sandbox-shared-codex,target=/home/agent/.codex,type=volume",
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
    "source=${localEnv:HOME}/.local/share/ai-agents,target=/home/agent/.local/share/ai-agents,type=bind,consistency=cached"
  ],
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "continue.continue",
        "openai.chatgpt",
        "rooveterinaryinc.roo-cline"
      ]
    }
  }
}
```

The `ai-sandbox-shared-claude` and `ai-sandbox-shared-codex` volumes are shared across all workspaces. Log in to Claude Code and Codex once inside any container and auth persists across all projects and rebuilds. Each workspace gets its own isolated home volume for everything else (shell state, harness config, VS Code extension binaries).

Then open the project in VS Code and choose **Reopen in Container**.

### Verifying it's working

After the container starts, run these checks in the VS Code integrated terminal:

**1. Confirm you are running as `agent`, not root**

```bash
whoami
# Expected: agent

id
# Expected: uid=1000(agent) gid=1000(agent) ...
```

**2. Confirm you are inside your project directory**

```bash
pwd
# Expected: /home/agent/projects/ai/<workspace-name>

ls
# Expected: your project files
```

**3. Confirm your host home is not accessible**

```bash
ls /root
# Expected: Permission denied

ls /home/agent/../..
# Expected: lists container root — should NOT contain your host username directory
# e.g. you should NOT see /home/yourhostname or any host-side home contents
```

**4. Confirm network is available (unless you disabled it)**

```bash
curl -s https://example.com --max-time 5 | head -c 50
# Expected: HTML content
```

**5. Confirm Roo Code and Continue are installed**

Open the Extensions panel (`⌘⇧X` / `Ctrl⇧X`) — both extensions should appear under **Installed**. If they show as **Install in Container**, click to install them (this only happens on first launch; they persist in the container home volume).

### What the container cannot access

Any path outside the directory you opened in VS Code is structurally invisible from inside the container — there is no mount for it. This means:

- The Roo Code and Continue agents cannot read files outside your project
- The terminal cannot `cd` to your host home or other projects
- Credentials at `~/.ssh`, `~/.aws`, `~/.config`, etc. are not present unless you explicitly inject them via `.ai-sandbox/secrets.env`

This is the same isolation guarantee as the CLI, applied to VS Code's extension and terminal environment.

---

## 11. Security limitations

`ai-sandbox` is a filesystem and process isolation layer, not a complete security sandbox. The container shares the host kernel. A kernel-level exploit (such as the Copy Fail vulnerability) can escape container isolation regardless of image configuration.

On every run, `ai-sandbox` prints a reminder:

```
WARNING: Container sandboxing depends on host kernel security.
Ensure your system is patched against recent vulnerabilities (e.g. Copy Fail / CVE-2026-31431).
```

Keep your host OS, Docker Desktop, and kernel up to date. See `SECURITY.md` for the full threat model.
