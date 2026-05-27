# ai-sandbox

**Version:** 2026-05-25

Run AI coding agents inside a Docker container. Only your current project directory is ever mounted — your home directory, SSH keys, and credentials stay on the host and are structurally inaccessible from inside the container.

---

## Why it exists

AI coding agents need broad filesystem access to be useful, but running them directly on a work machine means they can read (and write) your SSH keys, AWS credentials, `.env` files, and anything else in your home directory. Most agent harnesses have no isolation of their own.

`ai-sandbox` wraps any agent in a Docker container configured so that isolation is structural, not just encouraged:

- Only `$PWD` is bind-mounted — never `$HOME`
- The container runs as a non-root user (`agent`, UID 1000)
- Secrets injected at runtime never appear in logs
- Read-only and no-network modes are one flag away

The cost is one `docker run` wrapper. The benefit is that a compromised or misbehaving agent cannot reach your host filesystem beyond the project you gave it.

---

## Quick start

**1. Build the image** (once, from the `ai-sandbox` repo):

```bash
make build
```

**2. Add a config to your project:**

```
your-project/
└── .ai-sandbox/
    ├── sandbox.json      # required — commit this
    └── secrets.env       # API keys — gitignored
```

Minimal `sandbox.json`:

```json
{
  "defaultHarness": "claude",
  "defaultModel": "claude-sonnet",
  "harnesses": {
    "claude": { "command": "claude" }
  },
  "models": {
    "claude-sonnet": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-6"
    }
  },
  "sandbox": {
    "workspacePath": "/workspace",
    "readonly": false,
    "network": true
  }
}
```

`secrets.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
```

**3. Launch:**

```bash
cd your-project
ai-sandbox
```

---

## Key flags

| Flag | Effect |
|---|---|
| `ai-sandbox <harness>` | Launch a specific harness (e.g. `ai-sandbox aider`) |
| `--model <key>` | Override the default model for this run |
| `--readonly` | Mount `/workspace` read-only |
| `--no-network` | Disable all container network access |
| `--profile <name>` | Apply a named security profile from `sandbox.json` |
| `--shell` | Open a bash shell instead of launching a harness |
| `--dry-run` | Print resolved env vars and docker command without running |
| `--help` | Show all options |

---

## Supported providers

| Provider | How to configure |
|---|---|
| Anthropic | `provider: "anthropic"` + `ANTHROPIC_API_KEY` in `secrets.env` |
| OpenAI | `provider: "openai"` + `OPENAI_API_KEY` in `secrets.env` |
| OpenRouter | `provider: "openrouter"` + `OPENROUTER_API_KEY` in `secrets.env` |
| Ollama (local) | `provider: "ollama"` + `baseUrl: "http://host.docker.internal:11434"` |
| Google | `provider: "google"` + `GOOGLE_API_KEY` in `secrets.env` |

---

## VS Code dev container

The repo ships a `.devcontainer/devcontainer.template.json` for opening any project inside the sandbox container from VS Code. Copy it to your project as `.devcontainer/devcontainer.json`. Claude Code and Roo Code are installed automatically. Auth for Claude and Codex persists across workspaces and rebuilds via shared named Docker volumes.

See [`docs/TUTORIAL.md`](docs/TUTORIAL.md#10-vs-code-dev-container) for the full setup walkthrough.

---

## Security model

Docker provides filesystem and process isolation, not a complete security sandbox. The container shares the host kernel — a kernel-level exploit can escape regardless of image configuration. `ai-sandbox` prints a warning on every run and emits an additional warning on Linux kernels below 6.6.

Structurally enforced invariants:
- `$HOME` is never mounted
- `~/.ssh`, `~/.aws`, and similar paths are never mounted
- Secrets never appear in `--dry-run` stdout
- Temp env file is always deleted on exit
- Container always runs as non-root `agent`

---

## Further reading

| Document | What it covers |
|---|---|
| [`docs/TUTORIAL.md`](docs/TUTORIAL.md) | Full usage guide — config, harnesses, models, flags, devcontainer |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Threat model, kernel limitations, Copy Fail / CVE-2026-31431 |
| [`docs/AGENTS_AUTH.md`](docs/AGENTS_AUTH.md) | Agent auth design — what was tried, why it failed, how to validate new credential files |
| [`docs/VERSIONING.md`](docs/VERSIONING.md) | Tag and release conventions |
| [`docs/CHANGELOG.md`](docs/CHANGELOG.md) | Full history of changes |
| [`docs/PRD.md`](docs/PRD.md) | Product requirements and feature list |
