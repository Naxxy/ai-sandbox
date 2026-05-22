# PRD — AI Agent Sandbox (Docker-Based, Workspace-Driven)

---

## 1. Overview

### 1.1 Purpose

Build a **portable, secure, workspace-driven AI agent sandbox system** that allows developers to:

* Run AI coding agents (e.g. aider, opencode, claude CLI equivalents)
* Switch between **models and providers** (OpenRouter, OpenAI, Anthropic, Ollama, Gemini)
* Execute agents **inside a Docker container**
* Restrict filesystem access to only the mounted workspace
* Avoid leaking credentials or accessing host system data
* Use both **CLI workflows and optional VS Code-based UI workflows**

---

### 1.2 Core Philosophy

* **Workspace-first configuration**
* **Reproducible environments**
* **Zero implicit host access**
* **Pluggable harness + model abstraction**
* **Minimal friction to run (`ai-sandbox`)**

---

## 2. Target Users

### Primary

* Developers experimenting with AI coding agents
* Engineers working with local + remote models
* Users concerned about AI sandboxing/security

### Secondary

* Teams standardizing AI workflows across repos
* Researchers comparing agent/model performance

---

## 3. Key Features

### 3.1 Workspace-Based Configuration

Each project contains:

```text
.ai-sandbox/
  sandbox.json
  env
  secrets.env (gitignored)
  docker-compose.yml (optional)
```

The sandbox MUST:

* Automatically load config from `.ai-sandbox/sandbox.json`
* Fail clearly if config is missing

---

### 3.2 Global CLI Launcher

A single command:

```bash
ai-sandbox
```

MUST:

* Work from **any directory**
* Mount current directory → `/workspace`
* Parse `.ai-sandbox/sandbox.json`
* Launch container with correct harness + model

---

### 3.3 Harness Abstraction

Support multiple agent CLIs (“harnesses”):

Examples:

* aider
* opencode
* claude CLI (or equivalent)
* shell (fallback)

Config structure:

```json
"harnesses": {
  "aider": { "command": "aider" },
  "opencode": { "command": "opencode" },
  "claude": { "command": "claude" },
  "shell": { "command": "bash" }
}
```

Requirements:

* Must be extensible
* Must support arbitrary commands
* Must not assume a single provider

---

### 3.4 Model Abstraction

Support multiple providers:

* ollama (local)
* openrouter
* openai
* anthropic
* google

Config:

```json
"models": {
  "local-qwen": {
    "provider": "ollama",
    "model": "qwen3.5:4b",
    "baseUrl": "http://host.docker.internal:11434"
  }
}
```

System MUST:

* Translate model config → environment variables per harness
* Allow CLI override:

```bash
ai-sandbox --model openrouter-free
```

---

### 3.5 Docker Isolation

Container MUST:

* Mount only:

  * `/workspace`
  * optional persistent `/home/agent` volume
* NOT access:

  * `$HOME`
  * `~/.ssh`
  * `~/.aws`
  * system directories

---

### 3.6 Execution Modes

Support:

#### Default

```bash
ai-sandbox
```

#### Harness selection

```bash
ai-sandbox aider
```

#### Model override

```bash
ai-sandbox --model local-qwen
```

#### Read-only mode

```bash
ai-sandbox --readonly
```

#### No network (MANDATORY FEATURE)

```bash
ai-sandbox --no-network
```

Requirements:

* MUST disable all outbound/inbound network access for the container
* MUST be implemented via Docker networking flags (e.g. `--network none`)
* MUST prevent:

  * API calls (OpenAI, OpenRouter, etc.)
  * data exfiltration
* MUST still allow:

  * local filesystem operations
  * agent execution within `/workspace`

---

#### Shell debug

```bash
ai-sandbox --shell
```

---

### 3.7 Environment Handling

Load:

```text
.ai-sandbox/env
.ai-sandbox/secrets.env
```

Rules:

* `env` is committed
* `secrets.env` is gitignored
* Both injected into container

---

### 3.8 Persistent Container Home

Use Docker volume:

```text
/home/agent
```

Stores:

* tool installs
* caches
* agent configs

MUST NOT touch host home directory.

---

## 4. Non-Functional Requirements

### 4.1 Security

MUST:

* Never mount sensitive directories automatically
* Require explicit mounts only
* Support read-only mode
* Support no-network mode
* Avoid leaking secrets via logs

SHOULD:

* Warn if mounting parent directories like `/`
* Prevent accidental `~` mounting

---

### 4.2 Performance

* Container startup < 3 seconds (after build)
* Reuse image
* Cache dependencies

---

### 4.3 Portability

* Must work on:

  * macOS (Docker Desktop)
  * Linux (Docker Engine)

---

### 4.4 Extensibility

* Adding a new harness requires only config + install step
* Adding a new model requires only JSON entry

---

## 5. Architecture

```text
User CLI (ai-sandbox)
        ↓
Parse workspace config
        ↓
Resolve:
  - harness
  - model
  - env vars
        ↓
docker run
        ↓
Container
  - /workspace mounted
  - /home/agent volume
  - selected harness executed
```

---

## 6. File Specifications

### 6.1 sandbox.json (REQUIRED)

```json
{
  "defaultHarness": "aider",
  "defaultModel": "local-qwen",
  "harnesses": {},
  "models": {},
  "sandbox": {
    "workspacePath": "/workspace",
    "readonly": false,
    "network": true
  }
}
```

Validation:

* MUST validate JSON schema
* MUST fail with clear error

---

### 6.2 env

Plain key=value file

---

### 6.3 secrets.env

Same format, gitignored

---

## 7. Docker Image Requirements

### 7.1 Base Image Selection (Security-Critical)

The Docker image MUST use a **minimal, security-focused base image**.

Preferred options (in order):

1. `cgr.dev/chainguard/wolfi-base:latest` (preferred hardened base)
2. `debian:bookworm-slim` (best compatibility fallback)
3. `alpine:3.22` (acceptable lightweight option)

The system MUST NOT rely on large, general-purpose, unmaintained, or outdated base images.

---

### 7.2 Copy Fail / Kernel Vulnerability Consideration (CRITICAL)

The system MUST explicitly document and enforce awareness of the **Copy Fail vulnerability (e.g. CVE-2026-31431)** and similar Linux kernel privilege escalation vulnerabilities.

#### Key Principle

> Docker containers share the host kernel. A secure container image does NOT guarantee sandbox security if the host kernel is vulnerable.

#### Requirements

The project MUST:

* Clearly document that:

  * Copy Fail is a **host kernel vulnerability**
  * It cannot be mitigated solely via Docker image selection
* Require users to:

  * Run on a **patched kernel**
  * Keep Docker Desktop / host OS up to date

---

### 7.3 Runtime Safety Checks

The `ai-sandbox` CLI MUST:

* On startup, execute:

```bash
uname -a
```

* Display a warning message such as:

```text
WARNING: Container sandboxing depends on host kernel security.
Ensure your system is patched against recent vulnerabilities (e.g. Copy Fail).
```

* On Linux systems:

  * SHOULD warn if kernel version is older than known safe baselines (best-effort)

---

### 7.4 Security Positioning

The PRD MUST define:

```text
Docker is an isolation boundary for filesystem and process scope,
but NOT a complete security sandbox against kernel-level exploits.
```

---

### 7.5 Container Requirements

The image MUST:

* Run as non-root user (`agent`)
* Default working directory `/workspace`
* Include:

```text
bash
git
curl
jq
ripgrep
fd
python3 + pip
node + npm
```

---

## 8. CLI Tool Specification

### Name:

```bash
ai-sandbox
```

### Responsibilities:

* Parse CLI args
* Load config
* Resolve harness + model
* Generate docker command
* Execute container

### MUST:

* use `jq` for JSON parsing
* support help output

---

## 9. Stretch Goals

### 9.1 VS Code Dev Container Integration

Provide:

```text
.devcontainer/devcontainer.json
```

Capabilities:

* Run extensions inside container
* Install:

  * Roo
  * Continue
* Mount workspace safely

---

### 9.2 Model Capability Detection

Detect:

* tool support
* context size

Warn if:

* model unsuitable for agent use

---

### 9.3 Plugin System

Allow:

```json
"plugins": []
```

Future extensibility for:

* MCP servers
* tool injection

---

### 9.4 Sandbox Profiles

Example:

```json
"sandboxProfiles": {
  "strict": {
    "network": false,
    "readonly": true
  }
}
```

---

### 9.5 Multiple Containers

Support:

* running multiple isolated agents simultaneously

---

## 10. Success Criteria

### Functional

* Can run:

  ```bash
  ai-sandbox aider
  ```

  in any repo

* Agent can:

  * read/write `/workspace`
  * NOT access host filesystem

* Switching models works across providers

---

### Security

* No access to:

  * SSH keys
  * host home directory

* Secrets only accessible if explicitly provided

* User is clearly warned about kernel-level sandbox limitations

---

### Usability

* Zero Docker args required by user
* Setup per repo < 2 minutes
* Consistent behavior across machines

---

## 11. Example Usage

```bash
cd my-project

ai-sandbox
ai-sandbox aider
ai-sandbox --model openrouter-free
ai-sandbox --readonly
ai-sandbox --no-network
ai-sandbox --shell
```

---

## 12. Risks

| Risk                             | Mitigation                      |
| -------------------------------- | ------------------------------- |
| Agent escapes sandbox via mounts | Restrict mounts strictly        |
| Secrets leakage                  | Use env isolation               |
| Kernel exploit (Copy Fail)       | Require patched host + warnings |
| Model incompatibility            | Add warnings                    |
| Docker complexity                | Provide wrapper CLI             |

---

## 13. Deliverables

* Dockerfile
* ai-sandbox CLI script
* example `.ai-sandbox/`
* documentation
* devcontainer config (stretch)

---

## 14. Implementation Tasks (Ordered)

### Phase 1 — Core

1. Create Dockerfile (secure base)
2. Build image
3. Create CLI script
4. Implement config parsing
5. Implement docker run logic

### Phase 2 — Models

6. Add provider mapping logic
7. Add env injection

### Phase 3 — UX

8. Add flags
9. Add help + validation

### Phase 4 — Security

10. Add readonly mode
11. Add no-network mode
12. Add kernel warning checks

### Phase 5 — Stretch

13. Dev container support
14. Plugin system

---

## 15. Completion Definition

The project is complete when:

* A user can clone repo
* Add `.ai-sandbox/sandbox.json`
* Run `ai-sandbox`
* Successfully execute an AI agent inside a container
* Without exposing host system
* With explicit awareness of sandbox security limitations

---

## 16. Footnotes — Optional Future Hardening (NOT IMPLEMENTED)

The following are **explicitly NOT part of the MVP** and MUST NOT be implemented without review and approval:

* Dropping Linux capabilities (`--cap-drop=ALL`)
* Enforcing `no-new-privileges`
* Seccomp/AppArmor profiles
* Read-only root filesystem (`--read-only`)
* User namespace remapping
* gVisor / Kata Containers runtime isolation

These may be introduced in a future security-hardening phase after validation.

---

END OF PRD
