# Product Summary — ai-sandbox

## What it is

A portable, secure, workspace-driven CLI that runs AI coding agents inside a Docker container. Developers run agents (aider, opencode, claude, pi, etc.) with only their current project directory mounted — no home directory, SSH keys, or host credentials ever exposed.

---

## Philosophy

- **Workspace-first** — config lives with the project (`.ai-sandbox/sandbox.json`)
- **Zero implicit host access** — only `$PWD` is ever mounted
- **Pluggable harness + model abstraction** — swap agents and providers via config
- **Minimal friction** — one command: `ai-sandbox`

---

## Target users

Primary: developers running AI coding agents who want filesystem isolation from their host. Secondary: teams standardising AI workflows across repos.

---

## Key features (all implemented)

| Feature | Notes |
|---|---|
| CLI launcher | Walks up from `$PWD` to find `.ai-sandbox/sandbox.json`; works from any subdirectory |
| Harness abstraction | Any command registered in `sandbox.json` — aider, opencode, claude, pi, bash |
| Provider abstraction | ollama, openrouter, openai, anthropic, google — maps config to env vars |
| Read-only workspace | `--readonly` or `sandbox.readonly: true` |
| No-network mode | `--no-network` or `sandbox.network: false` — uses `--network none` |
| Extra mounts | `sandbox.extraMounts[]` — explicit, per-project, fail-safe `:ro` default |
| Config merge | `sandbox.local.json` with merge / append / replace modes |
| Sandbox profiles | Named combos of security settings (`--profile strict`) |
| Bind-mount home | `homeMount: "bind"` exposes `.ai-sandbox/home/` instead of an opaque volume |
| VS Code devcontainer | Shared auth volumes for Claude and Codex; per-workspace home isolation |
| Kernel warning | Printed on every run; additional warning on Linux kernel < 6.6 |

---

## Security model

Docker provides filesystem and process isolation, not a complete security sandbox. The container shares the host kernel — a kernel-level exploit (e.g. Copy Fail / CVE-2026-31431) can escape container isolation regardless of image configuration. See `SECURITY.md`.

Invariants enforced structurally:

- `$HOME` is never mounted
- `~/.ssh`, `~/.aws`, and similar paths are never mounted
- Secrets in `secrets.env` never appear in `--dry-run` stdout
- Temp env file always deleted on exit via `trap`
- Container runs as non-root `agent` (UID 1000)

---

## Stretch goals

| Goal | Status |
|---|---|
| VS Code devcontainer | Implemented |
| Sandbox profiles | Implemented |
| Plugin system | Stub — warns if `plugins` array is non-empty |
| Multiple simultaneous containers | Not implemented |
| Model capability detection | Not implemented |

---

## Risks

| Risk | Mitigation |
|---|---|
| Agent escapes via mounts | Extra mounts explicit and per-project; `$HOME` structurally absent |
| Secrets leakage | `secrets.env` bypasses `--dry-run`; temp file deleted on exit |
| Kernel exploit (Copy Fail) | Warning on every run; documented in `SECURITY.md` |
| Model incompatibility | Unknown provider exits 1 with a clear error message |

---

## Future hardening (not implemented — do not add without review)

- `--cap-drop=ALL` (Linux capability dropping)
- `no-new-privileges`
- Seccomp / AppArmor profiles
- `--read-only` root filesystem
- User namespace remapping
- gVisor / Kata Containers runtime isolation
