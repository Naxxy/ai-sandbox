# AI Agent Browser Sandbox — Requirements Summary

## Goal

Build a fully local, FOSS-based browser sandbox environment for AI agents.

The system must allow AI agents to:

* Use a real browser
* Maintain persistent sessions/cookies where required
* Authenticate into websites/services
* Perform browser automation tasks

While ensuring:

* Complete isolation from the user’s normal browser environment
* Strong containment of credentials, cookies, and filesystem access
* Minimal risk to the host machine and personal accounts

---

# Core Requirements

## Browser Isolation

The AI agent browser environment MUST:

* Use a completely separate browser profile (`user-data-dir`)
* Never access or reuse the host user’s normal browser profile
* Never access host browser cookies/history/passwords
* Never access iCloud Keychain/macOS Keychain/etc.

The solution should support:

* Multiple isolated profiles
* Persistent profiles for long-lived sessions
* Disposable/ephemeral profiles for risky tasks

Example profiles:

```text
profiles/
├── throwaway/
├── research/
├── google-drive-agent/
├── social-agent/
└── admin-review/
```

---

# Runtime Isolation

The browser environment MUST run inside a sandbox boundary.

Preferred options:

1. Rootless Docker
2. Podman
3. Lima VM
4. Lightweight VM/container approach

The sandbox MUST:

* Run without privileged mode
* Drop unnecessary Linux capabilities
* Use `no-new-privileges`
* Avoid host networking where possible
* Restrict filesystem mounts

The sandbox MUST NOT have:

* Access to the user’s `$HOME`
* Access to SSH keys
* Access to password managers
* Access to personal downloads/documents
* Access to host browser sessions

---

# Filesystem Requirements

Allowed mounts should be minimal and explicit.

Example:

```text
/workspace
/profiles
/cache
```

The AI agent should only access:

* Its own browser profile
* A constrained workspace folder

Everything else should remain isolated.

---

# Browser Requirements

Preferred browser stack:

* Chromium
* Firefox (optional)
* Playwright-compatible browser

Preferred automation stack:

* Playwright
* Playwright MCP
* browser-use
* MCP-compatible browser tooling

The browser MUST support:

* Persistent sessions/cookies
* Headless and visible modes
* Remote debugging
* Human inspection when required

---

# Networking Requirements

The sandbox should:

* Bind services to `127.0.0.1`
* Avoid exposing remote debugging publicly
* Support optional network restrictions

Stretch goals:

* Domain allowlists
* LAN isolation
* Selective outbound filtering
* Optional `--no-network` modes

---

# Security Requirements

The solution MUST:

* Treat the AI agent as potentially unsafe
* Minimise credential exposure
* Support compartmentalisation between tasks/accounts
* Prevent accidental access to personal identity/accounts

Preferred practices:

* Separate accounts for agent usage
* Separate OAuth sessions
* Scoped/restricted API tokens
* Human approval for dangerous actions

Dangerous actions include:

* Purchases
* Sending emails/messages
* Deleting/modifying data
* Financial/account settings changes

---

# UX Requirements

The system should support:

* Easy startup/shutdown
* Persistent named profiles
* Visual browser inspection
* Non-technical operator usage where possible

Preferred UX:

* One command startup
* Simple config files
* Per-profile configuration
* Workspace-local configuration

Example:

```text
agent-browser start google-drive-agent
```

---

# Configuration Requirements

Configuration should preferably live in:

* JSON
* YAML
* `.env`
* workspace-local config files

Configuration should support:

* Browser selection
* Profile selection
* Mounted folders
* Allowed tools
* Network policy
* Model/provider configuration

---

# Stretch Goals

## Additional Isolation

Optional future improvements:

* Firejail/bubblewrap support
* gVisor/Kata Containers
* MicroVMs
* Qubes-like separation
* SELinux/AppArmor profiles

## AI Integration

Support:

* Claude-style agents
* Codex/OpenAI agents
* OpenRouter
* Ollama/local LLMs
* MCP tools
* Multi-agent workflows

## Observability

Optional:

* Session recording
* Browser replay
* Audit logging
* Prompt/action review
* Approval workflows

---

# Non-Goals

The system does NOT need:

* Cloud browser providers
* SaaS orchestration
* Enterprise management tooling
* Browser fingerprint spoofing
* Anti-detection scraping systems

---

# Success Criteria

A successful implementation allows:

* An AI agent to log into websites inside the sandbox browser
* Persistent sessions to survive restarts
* Zero access to the host’s real browser/account environment
* Safe deletion/reset of sandbox profiles
* Local-only operation
* Reproducible setup across machines

The system should feel:

* Safe
* Inspectable
* Minimal
* Reproducible
* Operator-friendly
* Compatible with local AI workflows and MCP tooling
