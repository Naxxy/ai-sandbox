# Scratchpad — AI Sandbox Implementation

## Resume Point (next session)

Phases 6 and 7 complete. Latest: 7.1 read-only `sandbox.json` enforcement — overlay mount blocks harness writes unless `allowSharedConfigWrite: true` is set in `sandbox.local.json`. No remaining planned work.

---

## Current Status

| Step | Description | Status |
|------|-------------|--------|
| 1.1  | Dockerfile | COMPLETE |
| 1.2  | Build & tag image | COMPLETE |
| 1.3  | CLI skeleton | COMPLETE |
| 1.4  | Config parsing | COMPLETE |
| 1.5  | docker run logic | COMPLETE |
| 2.1  | Provider→env mapping | COMPLETE |
| 2.2  | Env file injection | COMPLETE |
| 3.1  | Full flag implementation | COMPLETE |
| 3.2  | Help & validation | COMPLETE |
| 4.1  | Read-only mode | COMPLETE |
| 4.2  | No-network mode | COMPLETE |
| 4.3  | Kernel security warning | COMPLETE |
| 5.1  | Dev container | COMPLETE |
| 5.2  | Plugin stub | COMPLETE |
| 5.3  | Sandbox profiles stub | COMPLETE |
| 6.1  | Extra mounts (CLI + devcontainer) | COMPLETE |
| 6.2  | Sandbox home introspection | COMPLETE |
| 6.3  | Core tooling in container image | COMPLETE |
| 6.4  | Persistent VS Code extension state | COMPLETE |
| 7.1  | Read-only sandbox.json enforcement | COMPLETE |

---

## Files

| File | Purpose |
|---|---|
| `src/Dockerfile` | `debian:bookworm-slim`, all required tools, `agent` UID 1000, `ARG VERSION`, `WORKDIR /workspace` |
| `Makefile` | `make build` → tags `ai-sandbox:latest` and `ai-sandbox:$(VERSION)`; run from project root |
| `bin/ai-sandbox` | Full CLI script (executable) |
| `.ai-sandbox/sandbox.json` | Test config: `shell` harness (default), `local-qwen` (ollama) + `openrouter-free` models |
| `CLAUDE.md` | Project identity, file map, architecture decisions, bash rules, security invariants |
| `docs/IMPLEMENTATION_PLAN.md` | Full step-by-step plan with validation commands |
| `docs/PRD.md` | Product requirements document |

---

## Key Decisions Made

- `debian:bookworm-slim` over Chainguard Wolfi — all apt packages available
- `fd-find` package symlinked to `/usr/local/bin/fd`
- `agent` user UID 1000 via `useradd --create-home`
- `--` args **replace** the container CMD (not append) — `--shell -- whoami` → `docker run ... whoami`
- `DRY_RUN_VARS` array + `_emit_env()` helper: model/env vars visible in `--dry-run`; `secrets.env` bypasses it and never appears in stdout
- No `set -euo pipefail` — explicit error checking throughout
- Case flag arms sorted lexicographically

---

## Bugs Fixed This Session (2026-05-05)

| Bug | Fix |
|---|---|
| `cmd+=($harness_cmd)` unquoted glob-split | `read -ra harness_args <<< "$harness_cmd"; cmd+=("${harness_args[@]}")` |
| `mktemp` result unchecked | Explicit empty-check + `exit 1` |
| `${2:?'msg'}` leaks literal quotes into error | Replaced with `[[ $# -lt 2 \|\| -z "$2" ]]` + `exit 1` |
| `realpath` not portable to macOS | Replaced with `cd "$dir" && pwd` |
| `emit_kernel_warning` arithmetic on empty vars | Guard `[[ -n "$major" && -n "$minor" ]]` before comparison |
| `show_help` wrote to stderr | Removed `>&2`; `--help` goes to stdout; error path passes `>&2` at call site |
| `--` args appended to CMD (broke `--shell -- whoami`) | `--` args now replace CMD; default CMD stored in `DOCKER_CMD_DEFAULT` |
| `--dry-run` showed opaque `--env-file /tmp/...` | Added `DRY_RUN_VARS`; env vars printed before docker command |
| `apply_profile` silently ignored `false` values | `false // empty` → `empty` in jq; fixed with `if .field != null then (.field \| tostring) else empty end` |

---

## Working Directory

`/Users/guglielmino.ashar/Documents/programming/ai-agents/ai-sandbox/`
