# Security

## Sandbox Scope

Docker provides an isolation boundary for **filesystem and process scope**, but is NOT a complete security sandbox against kernel-level exploits.

The container restricts:
- Filesystem access (only `/workspace` is bind-mounted; `$HOME`, `~/.ssh`, `~/.aws` are never mounted)
- Process isolation (non-root `agent` user, UID 1000)
- Network access (optional `--no-network` via `--network none`)

The container does **not** protect against:
- Host kernel vulnerabilities
- Privilege escalation via kernel exploits
- Shared kernel namespaces attacks

## Copy Fail Vulnerability (CVE-2026-31431)

**Copy Fail** is a Linux kernel privilege escalation vulnerability that allows a process inside a container to escape to the host. Because Docker containers share the host kernel, a vulnerable kernel negates the container isolation boundary regardless of how the image is configured.

**Docker image hardening cannot mitigate a vulnerable host kernel.**

### Mitigations

- Keep your host OS and kernel up to date
- On macOS: keep Docker Desktop updated (it manages its own Linux VM kernel)
- On Linux: ensure kernel ≥ 6.6 (LTS baseline with known fixes applied)
- Monitor your distribution's security advisories

## What This Tool Does

`ai-sandbox` emits a kernel warning on every invocation:

```
WARNING: Container sandboxing depends on host kernel security.
Ensure your system is patched against recent vulnerabilities (e.g. Copy Fail / CVE-2026-31431).
Kernel: <uname -r>
```

On Linux, if the running kernel predates the 6.6 LTS baseline, an additional warning is printed.

## VS Code Dev Container

The `.devcontainer/devcontainer.json` provides the same isolation guarantees as the CLI:

- Only `${localWorkspaceFolder}` is bind-mounted into the container, at `/workspace`
- `$HOME`, `~/.ssh`, `~/.aws`, and all other host paths are structurally absent — there is no bind-mount for them
- `/home/agent` is backed by a named Docker volume (`ai-sandbox-devcontainer-home`); this persists Claude Code credentials and VS Code extension auth across rebuilds without touching the host filesystem
- `/home/agent/.claude/settings.json` is bind-mounted read-only from `src/claude-settings.json` — Claude Code cannot modify its own permission rules at runtime
- The container runs as `agent` (UID 1000), not root
- The Roo Code and Continue extensions, and the integrated terminal, all operate within this boundary

No new attack surface is introduced relative to the CLI; the container and image are identical. The same kernel-level caveat applies: if the host kernel is vulnerable, container isolation can be escaped regardless of how VS Code or the extensions are configured.

---

## Future Hardening (Not Implemented)

The following are explicitly out of scope for the current MVP and must not be added without review:

- Dropping Linux capabilities (`--cap-drop=ALL`)
- `no-new-privileges` enforcement
- Seccomp/AppArmor profiles
- Read-only root filesystem (`--read-only`)
- User namespace remapping
- gVisor / Kata Containers runtime isolation
