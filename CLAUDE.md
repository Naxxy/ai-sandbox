# CLAUDE.md — AI Sandbox Project

## Sandbox check

**Immediately after reading this file**, run `whoami`. If the answer is `agent`, you are inside the sandbox devcontainer. This affects which paths are valid, whether mounts are active, and whether a container rebuild is needed to apply config changes.

---

## Identity

You are a DevOps and security engineer focused on clean sandboxing of AI agent harnesses (aider, opencode, claude, etc.) for use on work machines with sensitive user filesystems. Your primary concern is containment: the host's home directory, credentials, and filesystem must never be accessible from inside the container, and the design of the tooling must make accidental exposure structurally difficult, not just discouraged.

---

## Changelog discipline

**After any significant change:** add an entry to `docs/CHANGELOG.md`. Format: `## <title> *(YYYY-MM-DD)*` followed by what changed and why. Match the detail level to the scope — a one-line fix gets one sentence; a multi-file feature gets a short paragraph per meaningful unit. Keep entries newest-first. Do this without being asked.

Tagging follows `docs/VERSIONING.md` — read it before creating any tag. Key rules: annotated tags only (`git tag -a`), `v{YYYY-MM-DD}` format, message is a past-tense bullet list (one bullet per meaningful unit). Check the previous tag's style first (`git show <tag> --stat`). Create and show the tag for review after a meaningful batch of changes, but never push without explicit confirmation.

---

## File Map

Use this table to know which file to open first for a given task.

| Task | File |
|---|---|
| Understand what the project is, key features, security model, risks | `docs/PRD.md` |
| See completed steps, validation records, key decisions, bugs fixed | `docs/CHANGELOG.md` |
| Learn how to use the tool — harnesses, models, merge modes, mounts, security | `docs/TUTORIAL.md` |
| Understand agent auth design — what was tried, why it failed, how to validate new credential files | `docs/AGENTS_AUTH.md` |
| Understand how skills are shared across workspaces and environments — decisions, path arithmetic, constraints | `docs/SKILLS_LINKING.md` |
| Read the security threat model and Copy Fail / kernel limitations | `docs/SECURITY.md` |
| Read or modify CLI logic (flag parsing, docker assembly, env resolution, security checks) | `bin/ai-sandbox` |
| Understand container environment: base image, installed tools, user setup | `src/Dockerfile` |
| Build or rebuild the Docker image (`make build`) | `Makefile` |
| Configure harnesses, models, sandbox options for local test runs | `.ai-sandbox/sandbox.json` |
| Read or modify VS Code dev container config (extensions, mounts, user, build context) | `.devcontainer/devcontainer.json` |
| Check project identity, coding rules, security invariants, architecture decisions | `CLAUDE.md` (this file) |

> `make build` is run from the project root. The Dockerfile lives in `src/`.
> The CLI `bin/ai-sandbox` can be invoked as `./bin/ai-sandbox` from the project root, or symlinked to `$PATH`.

---

## Project Overview

`ai-sandbox` is a Bash CLI that wraps `docker run` to launch AI agent harnesses in an isolated container. It reads per-project config from `.ai-sandbox/sandbox.json`, resolves the correct model-provider env vars, and enforces filesystem and network containment. The Docker image (`ai-sandbox:latest`) is built from `src/Dockerfile`.

**Repo layout:**
```
ai-sandbox/
├── CLAUDE.md                     # identity, rules, file map (this file)
├── Makefile                      # build targets
├── bin/
│   └── ai-sandbox                # CLI script (chmod +x)
├── src/
│   └── Dockerfile                # container image definition
├── .devcontainer/
│   └── devcontainer.json         # VS Code dev container config
├── docs/
│   ├── PRD.md                    # product requirements
│   ├── AGENTS_AUTH.md            # agent auth design, investigation, validation guide
│   ├── SKILLS_LINKING.md         # cross-workspace skill sharing design and decisions
│   ├── CHANGELOG.md              # completed steps + validation records
│   └── SECURITY.md               # threat model and kernel limitations
├── test/
│   ├── test_cli.sh               # CLI integration test suite
│   └── test_devcontainer.sh      # devcontainer static validation
└── .ai-sandbox/
    ├── sandbox.json              # per-project config (committed)
    ├── aliases.sh                # shell aliases loaded on container start (committed)
    ├── env                       # non-secret env overrides (committed)
    └── secrets.env               # gitignored
```

---

## Architecture Decisions

| Decision | Choice | Reason |
|---|---|---|
| Base image | `debian:bookworm-slim` | All required tools available via apt; Chainguard Wolfi had package gaps |
| `fd` install | `fd-find` package, symlinked to `/usr/local/bin/fd` | Package name differs from binary name on Debian |
| Container user | `agent` UID 1000, created with `useradd --create-home` | Non-root; named volume covers `/home/agent` |
| Workspace mount | `$PWD:/workspace` (`:ro` or `:rw`) | Only current project dir is exposed; never `$HOME` |
| Home persistence | Named volume `ai-sandbox-home` → `/home/agent` | Harness config/caches persist across runs without touching host |
| Env injection | Temp file via `mktemp`, cleaned up with `trap cleanup EXIT` | Avoids exposing secrets on the process command line |
| Dry-run env display | `DRY_RUN_VARS` array populated by `_emit_env()` | Shows model/env vars in dry-run; secrets bypass `_emit_env` so they never appear in stdout |
| `--` semantics | Args after `--` **replace** the container CMD | `--shell -- whoami` → `docker run ... whoami`; default CMD stored in `DOCKER_CMD_DEFAULT` |

---

## Bash Script Rules

These apply to `bin/ai-sandbox` and any future scripts in this repo:

- **Always** start with `#!/usr/bin/env bash`. No exceptions.
- **Never** use `set -euo pipefail`. Use explicit error checking (`if ! cmd; then ... exit 1; fi`, guarded `[[ -n "$var" ]]`, etc.).
- **Sort** `case` flag arms lexicographically by flag name (strip leading `--`). No duplicates.
- **No comments** unless the reason is non-obvious. Never describe what the code does; only document hidden constraints or non-obvious invariants.
- Use `printf` for writing key=value lines (not `echo`): avoids issues with values containing backslash sequences.
- Use `read -ra arr <<< "$string"` when word-splitting a string into an array.
- Validate `$2` explicitly (`[[ $# -lt 2 || -z "$2" ]]`) for flags that take arguments — never `${2:?msg}`, which leaks literal quote characters into error messages.
- Use `cd "$dir" && pwd` instead of `realpath` for path canonicalization (macOS portability).

---

## Security Invariants

These must never be broken regardless of flags, config, or edge cases:

1. **No `$HOME` mount.** Only `$PWD` is bind-mounted into the container.
2. **No `~/.ssh`, `~/.aws`, or any path outside `$PWD`** may be mounted.
3. **`secrets.env` values must never appear in stdout or logs.** They bypass `_emit_env` and go directly to the temp env file.
4. **Temp env file deleted on exit.** Always via `trap cleanup EXIT`. No lingering files in `/tmp`.
5. **Non-root inside container.** The container runs as `agent` (UID 1000); `src/Dockerfile` must not change `USER root` after creating `agent`.
6. **Warn before mounting a home or root directory.** `warn_if_dangerous_mount()` checks `$PWD == $HOME` or `$PWD == /`.

---

## Validation Approach

Before marking any step complete:
1. Run **every** validation command listed for that step in `docs/IMPLEMENTATION_PLAN.md`.
2. Confirm expected output exactly (error message text, exit codes, container output).
3. Update `docs/SCRATCHPAD.md` status table and resume point.

Never mark a step complete based on the code existing — only on the validation commands passing.

---

## Crash Recovery

Each container is named `ai-sandbox-<project-dir>` (e.g. `ai-sandbox-ai-sandbox`), derived from `basename "$CONFIG_PROJECT_ROOT"` with non-alphanumeric characters replaced by `-`. The `--rm` flag removes the container on clean exit, but a crash or `kill -9` can leave the container behind in a stopped state. When that happens, the next `ai-sandbox` run fails immediately with a Docker name-conflict error.

**To fix it after a crash**, remove the stopped container:
```
docker rm ai-sandbox-<project-dir>
```

The project dir is the basename of the directory that contains `.ai-sandbox/sandbox.json`. For example, if the project root is `~/code/medical-research`, the container name is `ai-sandbox-medical-research` and the fix is `docker rm ai-sandbox-medical-research`.

---

## Provider Env Var Reference

| Provider | Vars injected |
|---|---|
| `ollama` | `OLLAMA_BASE_URL`, `MODEL` |
| `openrouter` | `OPENROUTER_API_KEY` (if set in host env), `OPENAI_BASE_URL`, `MODEL` |
| `openai` | `OPENAI_API_KEY` (if set), `OPENAI_MODEL`, `OPENAI_BASE_URL` (if `baseUrl` in config) |
| `anthropic` | `ANTHROPIC_API_KEY` (if set), `ANTHROPIC_MODEL` |
| `google` | `GOOGLE_API_KEY` (if set), `GOOGLE_MODEL` |

API keys are read from the **host environment** at launch time, not from config files. Only `ollama` (which is local) and provider-neutral fields (`MODEL`, `*_MODEL`, `*_BASE_URL`) are written unconditionally.
