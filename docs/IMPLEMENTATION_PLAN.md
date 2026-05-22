# AI Agent Sandbox — Implementation Plan

> Phases 6 and 7.1 are complete. See `docs/CHANGELOG.md` for the full implementation record.
> See `docs/SCRATCHPAD.md` for session history and key decisions.

---

## Phase 6 — Usability & Developer Experience (Complete)

All steps complete — see CHANGELOG for details.

---

## Phase 7 — Config Architecture (Complete)

### 7.1 Read-Only sandbox.json Enforcement ✓

Complete — see CHANGELOG for details.

---

## Example `sandbox.json` (reference)

```json
{
  "defaultHarness": "shell",
  "defaultModel": "local-qwen",
  "harnesses": {
    "aider":     { "command": "aider" },
    "opencode":  { "command": "opencode" },
    "claude":    { "command": "claude" },
    "shell":     { "command": "bash" }
  },
  "models": {
    "local-qwen": {
      "provider": "ollama",
      "model": "qwen3.5:4b",
      "baseUrl": "http://host.docker.internal:11434"
    },
    "openrouter-free": {
      "provider": "openrouter",
      "model": "mistralai/mistral-7b-instruct:free"
    }
  },
  "sandbox": {
    "workspacePath": "/workspace",
    "readonly": false,
    "network": true
  }
}
```
