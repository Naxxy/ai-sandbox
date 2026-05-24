#!/usr/bin/env bash
# Static validation of .devcontainer/devcontainer.json.
# These tests do not launch VS Code or Docker — they verify the config is
# correct and enforces the same security invariants as the CLI (no host home
# mounts, non-root user, workspace pinned to /workspace).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVCONTAINER="$PROJECT_ROOT/.devcontainer/devcontainer.json"

PASS=0
FAIL=0

pass() { echo "PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL  $1: $2" >&2; FAIL=$(( FAIL + 1 )); }

check_prerequisites() {
  if ! command -v jq > /dev/null 2>&1; then
    echo "SKIP  jq not found — required for devcontainer tests" >&2
    exit 1
  fi
}

test_file_exists() {
  if [[ -f "$DEVCONTAINER" ]]; then
    pass "5.1 file: .devcontainer/devcontainer.json exists"
  else
    fail "5.1 file: .devcontainer/devcontainer.json exists" "not found at $DEVCONTAINER"
  fi
}

test_valid_json() {
  if jq empty "$DEVCONTAINER" > /dev/null 2>&1; then
    pass "5.1 json: devcontainer.json is valid JSON"
  else
    fail "5.1 json: devcontainer.json is valid JSON" "jq parse error"
  fi
}

test_remote_user_is_agent() {
  local user
  user=$(jq -r '.remoteUser // empty' "$DEVCONTAINER")
  if [[ "$user" == "agent" ]]; then
    pass "5.1 security: remoteUser is agent (non-root)"
  else
    fail "5.1 security: remoteUser is agent (non-root)" "got: '$user'"
  fi
}

test_remote_user_not_root() {
  local user
  user=$(jq -r '.remoteUser // empty' "$DEVCONTAINER")
  if [[ "$user" != "root" && -n "$user" ]]; then
    pass "5.1 security: remoteUser is not root"
  else
    fail "5.1 security: remoteUser is not root" "got: '$user'"
  fi
}

test_workspace_folder() {
  local folder
  folder=$(jq -r '.workspaceFolder // empty' "$DEVCONTAINER")
  if [[ "$folder" == "/workspace" ]]; then
    pass "5.1 config: workspaceFolder is /workspace"
  else
    fail "5.1 config: workspaceFolder is /workspace" "got: '$folder'"
  fi
}

test_workspace_mount_target() {
  local mount
  mount=$(jq -r '.workspaceMount // empty' "$DEVCONTAINER")
  if echo "$mount" | grep -q "target=/workspace"; then
    pass "5.1 config: workspaceMount targets /workspace"
  else
    fail "5.1 config: workspaceMount targets /workspace" "got: '$mount'"
  fi
}

test_no_host_home_in_workspace_mount() {
  local mount home_escaped
  mount=$(jq -r '.workspaceMount // empty' "$DEVCONTAINER")
  home_escaped=$(printf '%s' "$HOME" | sed 's/[^^]/[&]/g; s/\^/\\^/g')
  if echo "$mount" | grep -qE "(source=~|source=\$HOME|localEnv:HOME)"; then
    fail "5.1 security: workspaceMount does not reference host home" "home path found in mount: $mount"
  else
    pass "5.1 security: workspaceMount does not reference host home"
  fi
}

test_no_host_home_in_mounts_array() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  # Allow ${localEnv:HOME}/subdir mounts (extra mounts); block bare home, .ssh, .aws
  if echo "$mounts" | grep -qE "(source=~[^/]|source=\\\$HOME[^/]|localEnv:HOME}[^/]|\.ssh|\.aws)"; then
    fail "5.1 security: mounts array does not expose bare host home or credentials" "found: $mounts"
  else
    pass "5.1 security: mounts array does not expose bare host home or credentials"
  fi
}

test_claude_settings_mount_readonly() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "src/claude-settings.json" \
    && echo "$mounts" | grep -q "target=/home/agent/.claude/settings.json" \
    && echo "$mounts" | grep -q "readonly"; then
    pass "6.4 security: claude settings bind-mounted readonly"
  else
    fail "6.4 security: claude settings bind-mounted readonly" "mounts: $mounts"
  fi
}

test_credentials_mount_present() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "localEnv:HOME.*\.credentials\.json" \
    && echo "$mounts" | grep -q "target=/home/agent/.claude/.credentials.json"; then
    pass "6.4 security: claude credentials bind-mounted into container"
  else
    fail "6.4 security: claude credentials bind-mounted into container" "mounts: $mounts"
  fi
}

test_extension_continue() {
  local found
  found=$(jq -r '.customizations.vscode.extensions[]? // empty' "$DEVCONTAINER" | grep -c "continue.continue")
  if [[ "$found" -ge 1 ]]; then
    pass "5.1 extensions: continue.continue listed"
  else
    fail "5.1 extensions: continue.continue listed" "not found in extensions array"
  fi
}

test_extension_roo() {
  local found
  found=$(jq -r '.customizations.vscode.extensions[]? // empty' "$DEVCONTAINER" | grep -c "rooveterinaryinc.roo-cline")
  if [[ "$found" -ge 1 ]]; then
    pass "5.1 extensions: rooveterinaryinc.roo-cline listed"
  else
    fail "5.1 extensions: rooveterinaryinc.roo-cline listed" "not found in extensions array"
  fi
}

test_extension_claude_code() {
  local found
  found=$(jq -r '.customizations.vscode.extensions[]? // empty' "$DEVCONTAINER" | grep -c "anthropic.claude-code")
  if [[ "$found" -ge 1 ]]; then
    pass "6.4 extensions: anthropic.claude-code listed"
  else
    fail "6.4 extensions: anthropic.claude-code listed" "not found in extensions array"
  fi
}

test_extension_chatgpt() {
  local found
  found=$(jq -r '.customizations.vscode.extensions[]? // empty' "$DEVCONTAINER" | grep -c "openai.chatgpt")
  if [[ "$found" -ge 1 ]]; then
    pass "6.4 extensions: openai.chatgpt listed"
  else
    fail "6.4 extensions: openai.chatgpt listed" "not found in extensions array"
  fi
}

test_docker_socket_mounted() {
  local mounts
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  if echo "$mounts" | grep -q "source=/var/run/docker.sock"; then
    pass "6.1 devcontainer: docker socket source in mounts"
  else
    fail "6.1 devcontainer: docker socket source in mounts" "mounts: $mounts"
  fi
  if echo "$mounts" | grep -q "target=/var/run/docker.sock"; then
    pass "6.1 devcontainer: docker socket target in mounts"
  else
    fail "6.1 devcontainer: docker socket target in mounts" "mounts: $mounts"
  fi
  if echo "$mounts" | grep "docker.sock" | grep -qv "readonly"; then
    pass "6.1 devcontainer: docker socket mount is not marked readonly"
  else
    fail "6.1 devcontainer: docker socket mount is not marked readonly" "mounts: $mounts"
  fi
}

test_image_field() {
  local image
  image=$(jq -r '.image // empty' "$DEVCONTAINER")
  if [[ "$image" == "ai-sandbox:latest" ]]; then
    pass "5.1 config: image is ai-sandbox:latest"
  else
    fail "5.1 config: image is ai-sandbox:latest" "got: '$image'"
  fi
}

test_agent_home_volume_mount() {
  local mounts home_mount
  mounts=$(jq -r '.mounts[]? // empty' "$DEVCONTAINER" 2>/dev/null)
  home_mount=$(echo "$mounts" | grep "target=/home/agent[^/]")
  if echo "$home_mount" | grep -q "type=volume"; then
    pass "6.4 persistence: named volume mounted at /home/agent"
  else
    fail "6.4 persistence: named volume mounted at /home/agent" "no volume-type mount targeting /home/agent found; mounts: $mounts"
  fi
}

main() {
  check_prerequisites

  test_file_exists
  test_valid_json
  test_remote_user_is_agent
  test_remote_user_not_root
  test_workspace_folder
  test_workspace_mount_target
  test_no_host_home_in_workspace_mount
  test_no_host_home_in_mounts_array
  test_claude_settings_mount_readonly
  test_credentials_mount_present
  test_extension_continue
  test_extension_roo
  test_extension_claude_code
  test_extension_chatgpt
  test_docker_socket_mounted
  test_image_field
  test_agent_home_volume_mount

  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

main "$@"
