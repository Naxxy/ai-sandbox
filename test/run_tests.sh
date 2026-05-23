#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_ROOT/bin/ai-sandbox"
CONFIG_DIR="$PROJECT_ROOT/.ai-sandbox"

PASS=0
FAIL=0
STASHED_LOCAL_CONFIG=""

pass() {
  echo "PASS  $1"
  PASS=$(( PASS + 1 ))
}

fail() {
  echo "FAIL  $1: $2" >&2
  FAIL=$(( FAIL + 1 ))
}

# Run CLI in --dry-run, discarding stderr noise
cli_dry()  { "$CLI" "$@" --dry-run 2>/dev/null; }
# Run CLI in --dry-run, keeping stderr (for tests that check warnings)
cli_dry2() { "$CLI" "$@" --dry-run 2>&1; }

check_prerequisites() {
  if ! docker image inspect ai-sandbox:latest > /dev/null 2>&1; then
    echo "SKIP  Docker image ai-sandbox:latest not found — run 'make build' first" >&2
    exit 1
  fi
  if [[ ! -x "$CLI" ]]; then
    fail "prerequisite" "bin/ai-sandbox not found or not executable"
    exit 1
  fi
}

setup() {
  cd "$PROJECT_ROOT" || exit 1
  echo "MY_VAR=hello"       > "$CONFIG_DIR/env"
  echo "SECRET_KEY=hunter2" > "$CONFIG_DIR/secrets.env"
  # Stash sandbox.local.json so all tests run against the baseline sandbox.json
  if [[ -f "$CONFIG_DIR/sandbox.local.json" ]]; then
    STASHED_LOCAL_CONFIG="$(mktemp /tmp/sandbox-local-XXXXXX.json)"
    cp "$CONFIG_DIR/sandbox.local.json" "$STASHED_LOCAL_CONFIG"
    rm "$CONFIG_DIR/sandbox.local.json"
  fi
}

cleanup() {
  rm -f "$CONFIG_DIR/env" "$CONFIG_DIR/secrets.env" "$CONFIG_DIR/sandbox.json.bak"
  rm -f /tmp/sandbox-test.json /tmp/em_out.txt /tmp/hm_out.txt /tmp/mm_out.txt
  rm -rf "$CONFIG_DIR/home"
  rm -f "$CONFIG_DIR/sandbox.local.json"
  [[ -d "$HOME/.ai-sandbox" ]] && rm -r "$HOME/.ai-sandbox"
  if [[ -n "$STASHED_LOCAL_CONFIG" && -f "$STASHED_LOCAL_CONFIG" ]]; then
    cp "$STASHED_LOCAL_CONFIG" "$CONFIG_DIR/sandbox.local.json"
    rm -f "$STASHED_LOCAL_CONFIG"
  fi
}

with_modified_config() {
  local modifier="$1"; shift
  cp "$CONFIG_DIR/sandbox.json" "$CONFIG_DIR/sandbox.json.bak"
  python3 -c "
import json
with open('$CONFIG_DIR/sandbox.json') as f: cfg = json.load(f)
$modifier
with open('$CONFIG_DIR/sandbox.json', 'w') as f: json.dump(cfg, f, indent=2)
"
  "$@"
  local rc=$?
  cp "$CONFIG_DIR/sandbox.json.bak" "$CONFIG_DIR/sandbox.json"
  rm -f "$CONFIG_DIR/sandbox.json.bak"
  return $rc
}

test_env_injection() {
  local out

  out=$("$CLI" --shell -- bash -c "echo MY_VAR=\$MY_VAR" 2>/dev/null)
  if echo "$out" | grep -q "MY_VAR=hello"; then
    pass "2.2 env: MY_VAR injected into container"
  else
    fail "2.2 env: MY_VAR injected into container" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "echo SECRET_KEY=\$SECRET_KEY" 2>/dev/null)
  if echo "$out" | grep -q "SECRET_KEY=hunter2"; then
    pass "2.2 env: SECRET_KEY injected into container"
  else
    fail "2.2 env: SECRET_KEY injected into container" "got: $out"
  fi

  if cli_dry2 | grep -qi "hunter2"; then
    fail "2.2 env: secrets not in --dry-run stdout" "secret value appeared in output"
  else
    pass "2.2 env: secrets not in --dry-run stdout"
  fi
}

test_flags() {
  local out exit_code

  out=$(cli_dry)
  if echo "$out" | grep -q "^docker run"; then
    pass "3.1 flags: --dry-run prints docker command"
  else
    fail "3.1 flags: --dry-run prints docker command" "got: $out"
  fi

  "$CLI" --dry-run > /dev/null 2>&1; exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    pass "3.1 flags: --dry-run exits 0"
  else
    fail "3.1 flags: --dry-run exits 0" "exit $exit_code"
  fi

  out=$(cli_dry aider | tail -1)
  if echo "$out" | grep -qE " aider$"; then
    pass "3.1 flags: positional harness sets CMD"
  else
    fail "3.1 flags: positional harness sets CMD" "got: $out"
  fi

  out=$(cli_dry --model local-qwen)
  if echo "$out" | grep -q "MODEL=qwen3.5:4b"; then
    pass "3.1 flags: --model overrides model"
  else
    fail "3.1 flags: --model overrides model" "got: $out"
  fi

  out=$(cli_dry --readonly | tail -1)
  if echo "$out" | grep -q ":ro"; then
    pass "3.1 flags: --readonly mounts :ro"
  else
    fail "3.1 flags: --readonly mounts :ro" "got: $out"
  fi

  out=$(cli_dry --no-network | tail -1)
  if echo "$out" | grep -q "\-\-network none"; then
    pass "3.1 flags: --no-network adds --network none"
  else
    fail "3.1 flags: --no-network adds --network none" "got: $out"
  fi

  out=$(cli_dry --shell | tail -1)
  if echo "$out" | grep -qE " bash$"; then
    pass "3.1 flags: --shell sets CMD to bash"
  else
    fail "3.1 flags: --shell sets CMD to bash" "got: $out"
  fi
}

test_help_and_validation() {
  local out flag_count exit_code

  flag_count=$("$CLI" --help 2>/dev/null | grep -cE "\-\-model|\-\-readonly|\-\-no-network|\-\-shell|\-\-dry-run")
  if [[ "$flag_count" -ge 5 ]]; then
    pass "3.2 help: all 5 flags documented"
  else
    fail "3.2 help: all 5 flags documented" "only $flag_count found"
  fi

  "$CLI" --help > /dev/null 2>&1; exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    pass "3.2 help: --help exits 0"
  else
    fail "3.2 help: --help exits 0" "exit $exit_code"
  fi

  out=$("$CLI" unknown-harness 2>&1)
  if echo "$out" | grep -q "Harness 'unknown-harness' not defined"; then
    pass "3.2 validation: unknown harness error"
  else
    fail "3.2 validation: unknown harness error" "got: $out"
  fi

  out=$("$CLI" --model ghost-model 2>&1)
  if echo "$out" | grep -q "Model 'ghost-model' not defined"; then
    pass "3.2 validation: unknown model error"
  else
    fail "3.2 validation: unknown model error" "got: $out"
  fi

  mkdir -p "$HOME/.ai-sandbox"
  cp "$CONFIG_DIR/sandbox.json" "$HOME/.ai-sandbox/sandbox.json"
  out=$(cd "$HOME" && "$CLI" --dry-run 2>&1)
  if echo "$out" | grep -qi "potentially unsafe"; then
    pass "3.2 validation: home directory mount warning"
  else
    fail "3.2 validation: home directory mount warning" "got: $out"
  fi
  rm -r "$HOME/.ai-sandbox"
}

test_readonly() {
  local out exit_code

  "$CLI" --readonly --shell -- bash -c "touch /workspace/test_rw_file" > /dev/null 2>&1
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    pass "4.1 readonly: write blocked with --readonly"
  else
    fail "4.1 readonly: write blocked with --readonly" "expected non-zero exit, got 0"
  fi

  out=$("$CLI" --shell -- bash -c "touch /workspace/test_rw_file && echo OK && rm /workspace/test_rw_file" 2>/dev/null | tail -1)
  if [[ "$out" == "OK" ]]; then
    pass "4.1 readonly: write succeeds without --readonly"
  else
    fail "4.1 readonly: write succeeds without --readonly" "got: $out"
  fi
}

test_no_network() {
  local out

  out=$("$CLI" --no-network --shell -- bash -c "curl -s https://example.com --max-time 3 || echo BLOCKED" 2>/dev/null | tail -1)
  if [[ "$out" == "BLOCKED" ]]; then
    pass "4.2 network: --no-network blocks outbound"
  else
    fail "4.2 network: --no-network blocks outbound" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "curl -s https://example.com --max-time 5 | head -c 15" 2>/dev/null)
  if echo "$out" | grep -qi "doctype\|html"; then
    pass "4.2 network: outbound works by default"
  else
    fail "4.2 network: outbound works by default" "got: $out"
  fi

  out=$("$CLI" --no-network --shell -- bash -c "echo test > /workspace/net_test.txt && cat /workspace/net_test.txt && rm /workspace/net_test.txt" 2>/dev/null | tail -1)
  if [[ "$out" == "test" ]]; then
    pass "4.2 network: filesystem still works with --no-network"
  else
    fail "4.2 network: filesystem still works with --no-network" "got: $out"
  fi
}

test_kernel_warning() {
  local count

  count=$(cli_dry2 | grep -c "WARNING")
  if [[ "$count" -ge 1 ]]; then
    pass "4.3 kernel: WARNING appears on every invocation"
  else
    fail "4.3 kernel: WARNING appears on every invocation" "count=$count"
  fi

  if [[ -f "$PROJECT_ROOT/docs/SECURITY.md" ]]; then
    pass "4.3 kernel: SECURITY.md exists"
  else
    fail "4.3 kernel: SECURITY.md exists" "file not found"
  fi

  if grep -qi "copy fail" "$PROJECT_ROOT/docs/SECURITY.md"; then
    pass "4.3 kernel: SECURITY.md documents Copy Fail"
  else
    fail "4.3 kernel: SECURITY.md documents Copy Fail" "string not found"
  fi
}

test_plugins() {
  local out
  with_modified_config "cfg['plugins'] = ['mcp-server']" \
    bash -c "out=\$('$CLI' --dry-run 2>&1); echo \"\$out\"" > /tmp/plugin_out.txt 2>&1
  out=$(cat /tmp/plugin_out.txt); rm -f /tmp/plugin_out.txt

  if echo "$out" | grep -qi "plugin.*not yet implemented\|plugin.*ignoring"; then
    pass "5.2 plugins: warning when plugins array non-empty"
  else
    fail "5.2 plugins: warning when plugins array non-empty" "got: $out"
  fi
}

test_profiles() {
  local out
  with_modified_config "cfg['sandboxProfiles'] = {'strict': {'network': False, 'readonly': True}}" \
    bash -c "out=\$('$CLI' --profile strict --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/profile_out.txt 2>&1
  out=$(cat /tmp/profile_out.txt); rm -f /tmp/profile_out.txt

  if echo "$out" | grep -q "\-\-network none"; then
    pass "5.3 profiles: strict profile disables network"
  else
    fail "5.3 profiles: strict profile disables network" "got: $out"
  fi

  if echo "$out" | grep -q ":ro"; then
    pass "5.3 profiles: strict profile sets readonly"
  else
    fail "5.3 profiles: strict profile sets readonly" "got: $out"
  fi
}

test_config_precedence() {
  local out

  # sandbox.json alone: base models and harnesses available, no extra mounts
  out=$(cli_dry 2>/dev/null)
  if echo "$out" | grep -q "docker run" && ! echo "$out" | grep -q " -v /var/run"; then
    pass "6.1 config-precedence: sandbox.json used alone when no sandbox.local.json present"
  else
    fail "6.1 config-precedence: sandbox.json used alone when no sandbox.local.json present" "got: $out"
  fi

  # sandbox.local.json partial override: only defaultModel changed, harnesses inherited from sandbox.json
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{ "defaultModel": "openrouter-free" }
LOCALJSON
  out=$(cli_dry 2>/dev/null)
  rm -f "$CONFIG_DIR/sandbox.local.json"
  # openrouter env var proves local model override was applied
  if echo "$out" | grep -q "OPENAI_BASE_URL=https://openrouter.ai"; then
    pass "6.1 config-precedence: sandbox.local.json overrides defaultModel"
  else
    fail "6.1 config-precedence: sandbox.local.json overrides defaultModel" "got: $out"
  fi
  # harness CMD should still be bash (inherited from sandbox.json's harnesses)
  if echo "$out" | grep -qE " bash$"; then
    pass "6.1 config-precedence: harnesses inherited from sandbox.json when not in sandbox.local.json"
  else
    fail "6.1 config-precedence: harnesses inherited from sandbox.json when not in sandbox.local.json" "got: $out"
  fi

  # sandbox.local.json partial override: only extraMounts added
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{ "sandbox": { "extraMounts": [{ "host": "/var/run/docker.sock", "container": "/var/run/docker.sock", "readonly": false }] } }
LOCALJSON
  out=$(cli_dry 2>/dev/null | tail -1)
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if echo "$out" | grep -q "/var/run/docker.sock:/var/run/docker.sock:rw"; then
    pass "6.1 config-precedence: sandbox.local.json adds extraMounts without redefining other keys"
  else
    fail "6.1 config-precedence: sandbox.local.json adds extraMounts without redefining other keys" "got: $out"
  fi

  # sandbox.local.json invalid JSON → error exit 1
  printf '{bad json' > "$CONFIG_DIR/sandbox.local.json"
  out=$("$CLI" --dry-run 2>&1); local rc=$?
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if [[ $rc -ne 0 ]] && echo "$out" | grep -q "Invalid JSON in sandbox.local.json"; then
    pass "6.1 config-precedence: invalid sandbox.local.json → error exit 1"
  else
    fail "6.1 config-precedence: invalid sandbox.local.json → error exit 1" "rc=$rc got: $out"
  fi
}

test_extra_mounts() {
  local out

  # Empty extraMounts → only the four standard -v flags (workspace + sandbox.json:ro + home + claude-settings:ro)
  out=$(cli_dry | tail -1)
  local v_count
  v_count=$(echo "$out" | grep -o ' -v ' | wc -l)
  if [[ "$v_count" -eq 4 ]]; then
    pass "6.1 extra-mounts: empty extraMounts produces no extra mounts"
  else
    fail "6.1 extra-mounts: empty extraMounts produces no extra mounts" "got $v_count -v flags: $out"
  fi

  # readonly:true → :ro
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '/tmp', 'container': '/mnt/test', 'readonly': True}]" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "/tmp:/mnt/test:ro"; then
    pass "6.1 extra-mounts: readonly:true → :ro"
  else
    fail "6.1 extra-mounts: readonly:true → :ro" "got: $out"
  fi

  # readonly omitted → :ro (default, safe)
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '/tmp', 'container': '/mnt/test'}]" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "/tmp:/mnt/test:ro"; then
    pass "6.1 extra-mounts: readonly omitted defaults to :ro"
  else
    fail "6.1 extra-mounts: readonly omitted defaults to :ro" "got: $out"
  fi

  # ~ expands to $HOME
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '~/.cache', 'container': '/mnt/cache', 'readonly': True}]" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "${HOME}/.cache:/mnt/cache:ro"; then
    pass "6.1 extra-mounts: ~ expands to \$HOME"
  else
    fail "6.1 extra-mounts: ~ expands to \$HOME" "got: $out"
  fi

  # Missing host field → error exit 1
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'container': '/mnt/test'}]" \
    bash -c "'$CLI' --dry-run 2>&1; echo \"exit:\$?\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "missing required" && echo "$out" | grep -q "exit:1"; then
    pass "6.1 extra-mounts: missing host field → error exit 1"
  else
    fail "6.1 extra-mounts: missing host field → error exit 1" "got: $out"
  fi

  # Missing container field → error exit 1
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '/tmp'}]" \
    bash -c "'$CLI' --dry-run 2>&1; echo \"exit:\$?\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "missing required" && echo "$out" | grep -q "exit:1"; then
    pass "6.1 extra-mounts: missing container field → error exit 1"
  else
    fail "6.1 extra-mounts: missing container field → error exit 1" "got: $out"
  fi

  # Home path in extraMounts triggers dangerous-mount warning
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '~', 'container': '/mnt/home', 'readonly': True}]" \
    bash -c "'$CLI' --dry-run 2>&1" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -qi "potentially unsafe"; then
    pass "6.1 extra-mounts: home path in extraMounts triggers warning"
  else
    fail "6.1 extra-mounts: home path in extraMounts triggers warning" "got: $out"
  fi

  # No extraMounts key → backward-compatible, no error
  with_modified_config \
    "cfg['sandbox'].pop('extraMounts', None)" \
    bash -c "'$CLI' --dry-run 2>/dev/null; echo \"exit:\$?\"" > /tmp/em_out.txt 2>&1
  out=$(cat /tmp/em_out.txt); rm -f /tmp/em_out.txt
  if echo "$out" | grep -q "docker run" && echo "$out" | grep -q "exit:0"; then
    pass "6.1 extra-mounts: absent extraMounts key → no error"
  else
    fail "6.1 extra-mounts: absent extraMounts key → no error" "got: $out"
  fi
}

test_merge_mode() {
  local out

  # append: arrays from both files are concatenated
  with_modified_config \
    "cfg['sandbox']['extraMounts'] = [{'host': '/tmp/base', 'container': '/mnt/base'}]" \
    bash -c "
cat > '$CONFIG_DIR/sandbox.local.json' << 'LOCALJSON'
{\"mergeMode\":\"append\",\"sandbox\":{\"extraMounts\":[{\"host\":\"/tmp/local\",\"container\":\"/mnt/local\"}]}}
LOCALJSON
out=\$('$CLI' --dry-run 2>/dev/null | tail -1)
rm -f '$CONFIG_DIR/sandbox.local.json'
echo \"\$out\"
" > /tmp/mm_out.txt 2>&1
  out=$(cat /tmp/mm_out.txt); rm -f /tmp/mm_out.txt
  if echo "$out" | grep -q "/tmp/base:/mnt/base" && echo "$out" | grep -q "/tmp/local:/mnt/local"; then
    pass "merge-mode: append concatenates extraMounts arrays from base and local"
  else
    fail "merge-mode: append concatenates extraMounts arrays from base and local" "got: $out"
  fi

  # replace: local is used as-is; models defined only in base are not available
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{
  "mergeMode": "replace",
  "defaultHarness": "shell",
  "defaultModel": "local-only",
  "harnesses": {"shell": {"command": "bash"}},
  "models": {
    "local-only": {"provider": "ollama", "model": "local:1", "baseUrl": "http://localhost:11434"}
  },
  "sandbox": {"workspacePath": "/workspace", "readonly": false, "network": true}
}
LOCALJSON
  out=$("$CLI" --model openrouter-free --dry-run 2>&1); local rc=$?
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if [[ $rc -ne 0 ]] && echo "$out" | grep -q "not defined"; then
    pass "merge-mode: replace does not inherit base models"
  else
    fail "merge-mode: replace does not inherit base models" "rc=$rc got: $out"
  fi

  # merge (explicit): default behavior preserved
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{"mergeMode": "merge", "defaultModel": "openrouter-free"}
LOCALJSON
  out=$(cli_dry 2>/dev/null)
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if echo "$out" | grep -q "OPENAI_BASE_URL=https://openrouter.ai"; then
    pass "merge-mode: explicit merge overrides defaultModel"
  else
    fail "merge-mode: explicit merge overrides defaultModel" "got: $out"
  fi

  # unknown mergeMode → error exit 1
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{"mergeMode": "superpatch"}
LOCALJSON
  out=$("$CLI" --dry-run 2>&1); rc=$?
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "mergeMode\|superpatch"; then
    pass "merge-mode: unknown mergeMode → error exit 1"
  else
    fail "merge-mode: unknown mergeMode → error exit 1" "rc=$rc got: $out"
  fi
}

test_config_readonly() {
  local out

  # Default (no sandbox.local.json, running from project root): sandbox.json gets :ro overlay
  out=$(cli_dry | tail -1)
  if echo "$out" | grep -q "sandbox\.json.*:ro"; then
    pass "7.1 config-readonly: sandbox.json mounted :ro inside container by default"
  else
    fail "7.1 config-readonly: sandbox.json mounted :ro inside container by default" "got: $out"
  fi

  # allowSharedConfigWrite: true → :ro overlay omitted
  cat > "$CONFIG_DIR/sandbox.local.json" << 'LOCALJSON'
{"allowSharedConfigWrite": true}
LOCALJSON
  out=$(cli_dry 2>/dev/null | tail -1)
  rm -f "$CONFIG_DIR/sandbox.local.json"
  if ! echo "$out" | grep -q "sandbox\.json.*:ro"; then
    pass "7.1 config-readonly: allowSharedConfigWrite:true omits :ro overlay"
  else
    fail "7.1 config-readonly: allowSharedConfigWrite:true omits :ro overlay" "got: $out"
  fi
}

test_home_mount_bind() {
  local out home_dir
  home_dir="$CONFIG_DIR/home"
  rm -rf "$home_dir"

  # bind mode → -v uses .ai-sandbox/home path with :rw
  with_modified_config \
    "cfg['sandbox']['homeMount'] = 'bind'" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/hm_out.txt 2>&1
  out=$(cat /tmp/hm_out.txt); rm -f /tmp/hm_out.txt
  if echo "$out" | grep -q "/.ai-sandbox/home:/home/agent:rw"; then
    pass "6.2 home-mount: bind mode adds :rw bind mount to .ai-sandbox/home"
  else
    fail "6.2 home-mount: bind mode adds :rw bind mount to .ai-sandbox/home" "got: $out"
  fi

  # bind mode → directory created automatically
  if [[ -d "$home_dir" ]]; then
    pass "6.2 home-mount: .ai-sandbox/home/ created automatically"
  else
    fail "6.2 home-mount: .ai-sandbox/home/ created automatically" "dir not found"
  fi

  # bind mode with .gitignore present → entry appended
  rm -rf "$home_dir"
  printf '' > "$PROJECT_ROOT/.gitignore"
  with_modified_config \
    "cfg['sandbox']['homeMount'] = 'bind'" \
    bash -c "'$CLI' --dry-run 2>/dev/null" > /dev/null 2>&1
  if grep -qF '.ai-sandbox/home/' "$PROJECT_ROOT/.gitignore"; then
    pass "6.2 home-mount: .ai-sandbox/home/ appended to .gitignore on creation"
  else
    fail "6.2 home-mount: .ai-sandbox/home/ appended to .gitignore on creation" "not found in .gitignore"
  fi
  rm -f "$PROJECT_ROOT/.gitignore"
  rm -rf "$home_dir"

  # volume mode → named volume
  with_modified_config \
    "cfg['sandbox']['homeMount'] = 'volume'" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/hm_out.txt 2>&1
  out=$(cat /tmp/hm_out.txt); rm -f /tmp/hm_out.txt
  if echo "$out" | grep -q "ai-sandbox-home-"; then
    pass "6.2 home-mount: volume mode uses named docker volume"
  else
    fail "6.2 home-mount: volume mode uses named docker volume" "got: $out"
  fi

  # absent homeMount → defaults to named volume
  with_modified_config \
    "cfg['sandbox'].pop('homeMount', None)" \
    bash -c "out=\$('$CLI' --dry-run 2>/dev/null | tail -1); echo \"\$out\"" > /tmp/hm_out.txt 2>&1
  out=$(cat /tmp/hm_out.txt); rm -f /tmp/hm_out.txt
  if echo "$out" | grep -q "ai-sandbox-home-"; then
    pass "6.2 home-mount: absent homeMount defaults to named volume"
  else
    fail "6.2 home-mount: absent homeMount defaults to named volume" "got: $out"
  fi
}

test_e2e() {
  local out count exit_code

  out=$("$CLI" --shell -- bash -c "pwd && whoami" 2>/dev/null)
  if echo "$out" | grep -q "/workspace" && echo "$out" | grep -q "agent"; then
    pass "E2E 1: container starts at /workspace as agent"
  else
    fail "E2E 1: container starts at /workspace as agent" "got: $out"
  fi

  out=$(cli_dry --model local-qwen)
  if echo "$out" | grep -q "MODEL=qwen3.5:4b"; then
    pass "E2E 2: model override via --model"
  else
    fail "E2E 2: model override via --model" "got: $out"
  fi

  out=$("$CLI" --readonly --shell -- bash -c "touch /workspace/x 2>&1 || echo BLOCKED" 2>/dev/null | tail -1)
  if [[ "$out" == "BLOCKED" ]]; then
    pass "E2E 3: readonly enforcement"
  else
    fail "E2E 3: readonly enforcement" "got: $out"
  fi

  out=$("$CLI" --no-network --shell -- bash -c "curl -s https://example.com --max-time 2 2>&1 || echo BLOCKED" 2>/dev/null | tail -1)
  if [[ "$out" == "BLOCKED" ]]; then
    pass "E2E 4: network isolation"
  else
    fail "E2E 4: network isolation" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "ls /root 2>&1; ls /home/\$(whoami) 2>&1 | wc -l" 2>/dev/null)
  if echo "$out" | grep -q "Permission denied\|cannot open" && echo "$out" | grep -q "^0$"; then
    pass "E2E 5: no host filesystem leakage"
  else
    fail "E2E 5: no host filesystem leakage" "got: $out"
  fi

  count=$(cli_dry2 | grep -c "WARNING")
  if [[ "$count" -ge 1 ]]; then
    pass "E2E 6: kernel warning present"
  else
    fail "E2E 6: kernel warning present" "count=$count"
  fi

  "$CLI" --help > /dev/null 2>&1; exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    pass "E2E 7: --help exits 0"
  else
    fail "E2E 7: --help exits 0" "exit $exit_code"
  fi
}

test_claude_settings() {
  local out exit_code settings_file
  settings_file="$PROJECT_ROOT/src/claude-settings.json"

  if [[ -f "$settings_file" ]]; then
    pass "claude-settings: src/claude-settings.json exists"
  else
    fail "claude-settings: src/claude-settings.json exists" "not found"
    return
  fi

  if jq empty "$settings_file" > /dev/null 2>&1; then
    pass "claude-settings: src/claude-settings.json is valid JSON"
  else
    fail "claude-settings: src/claude-settings.json is valid JSON" "jq parse error"
    return
  fi

  local default_mode
  default_mode="$(jq -r '.permissions.defaultMode // empty' "$settings_file")"
  if [[ "$default_mode" == "bypassPermissions" ]]; then
    pass "claude-settings: defaultMode is bypassPermissions"
  else
    fail "claude-settings: defaultMode is bypassPermissions" "got: $default_mode"
  fi

  local ask_count
  ask_count="$(jq '[.permissions.ask[]? | select(test("sudo|su "))] | length' "$settings_file")"
  if [[ "$ask_count" -ge 2 ]]; then
    pass "claude-settings: ask list contains sudo and su patterns"
  else
    fail "claude-settings: ask list contains sudo and su patterns" "got $ask_count matching entries"
  fi

  local sudo_in_deny
  sudo_in_deny="$(jq '[.permissions.deny[]? | select(test("sudo"))] | length' "$settings_file")"
  if [[ "$sudo_in_deny" -eq 0 ]]; then
    pass "claude-settings: sudo is not in deny list"
  else
    fail "claude-settings: sudo is not in deny list" "found $sudo_in_deny deny entries matching sudo"
  fi

  local deny_count
  deny_count="$(jq '.permissions.deny | length' "$settings_file")"
  if [[ "$deny_count" -ge 10 ]]; then
    pass "claude-settings: deny list has sufficient entries ($deny_count)"
  else
    fail "claude-settings: deny list has sufficient entries" "only $deny_count entries"
  fi

  out=$(cli_dry | tail -1)
  if echo "$out" | grep -q "claude-settings\.json:/home/agent/\.claude/settings\.json:ro"; then
    pass "claude-settings: settings file mounted :ro in dry-run"
  else
    fail "claude-settings: settings file mounted :ro in dry-run" "got: $out"
  fi

  out=$(cli_dry2)
  if echo "$out" | grep -q "claude settings mounted read-only"; then
    pass "claude-settings: [sandbox] log message on stderr"
  else
    fail "claude-settings: [sandbox] log message on stderr" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "cat /home/agent/.claude/settings.json" 2>/dev/null)
  if echo "$out" | grep -q "bypassPermissions"; then
    pass "claude-settings: settings file readable inside container"
  else
    fail "claude-settings: settings file readable inside container" "got: $out"
  fi

  "$CLI" --shell -- bash -c "echo x > /home/agent/.claude/settings.json" > /dev/null 2>&1
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    pass "claude-settings: write blocked by :ro bind mount"
  else
    fail "claude-settings: write blocked by :ro bind mount" "write succeeded unexpectedly"
  fi
}

test_sudo() {
  local out

  out=$("$CLI" --shell -- bash -c "which sudo" 2>/dev/null)
  if echo "$out" | grep -q "/sudo"; then
    pass "sudo: binary present in container"
  else
    fail "sudo: binary present in container" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "sudo whoami" 2>/dev/null)
  if [[ "$out" == "root" ]]; then
    pass "sudo: agent can sudo without password (NOPASSWD)"
  else
    fail "sudo: agent can sudo without password (NOPASSWD)" "got: $out"
  fi

  out=$("$CLI" --shell -- bash -c "sudo id -u" 2>/dev/null)
  if [[ "$out" == "0" ]]; then
    pass "sudo: sudo id -u returns 0"
  else
    fail "sudo: sudo id -u returns 0" "got: $out"
  fi
}

main() {
  check_prerequisites
  setup
  trap cleanup EXIT

  test_env_injection
  test_flags
  test_help_and_validation
  test_readonly
  test_no_network
  test_kernel_warning
  test_plugins
  test_profiles
  test_config_precedence
  test_extra_mounts
  test_merge_mode
  test_config_readonly
  test_home_mount_bind
  test_claude_settings
  test_sudo
  test_e2e

  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

main "$@"
