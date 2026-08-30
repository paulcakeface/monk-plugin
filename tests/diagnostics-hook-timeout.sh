#!/usr/bin/env sh
# Regression: PostToolUse diagnostics wrappers must not block indefinitely when
# the compiled monk-agent helper wedges. Healthy helper output is preserved.
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
root="$(mktemp -d)"
cleanup() { rm -rf "$root"; }
trap cleanup EXIT HUP INT TERM

agent="$root/monk-agent"
cat >"$agent" <<'AGENT'
#!/usr/bin/env sh
cat >/dev/null
if [ "${MONK_TEST_DIAGNOSTICS_MODE:-ok}" = "hang" ]; then
  sleep 30
  exit 0
fi
case "$*" in
  *antigravity*) printf '%s\n' '{}' ;;
  *) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}' ;;
esac
AGENT
chmod +x "$agent"

payload='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/MANIFEST"}}'

run_bounded_case() {
  hook="$1"
  expected="$2"
  started="$(date +%s)"
  set +e
  output="$(printf '%s\n' "$payload" | \
    MONK_AGENT_PATH="$agent" \
    MONK_DIAGNOSTICS_HELPER_TIMEOUT=1 \
    MONK_TEST_DIAGNOSTICS_MODE=hang \
    timeout 5 "$repo/$hook" 2>"$root/stderr")"
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))

  [ "$status" -eq 0 ]
  [ "$elapsed" -le 4 ]
  [ "$output" = "$expected" ]
  [ ! -s "$root/stderr" ]
}

run_healthy_case() {
  hook="$1"
  expected="$2"
  output="$(printf '%s\n' "$payload" | \
    MONK_AGENT_PATH="$agent" \
    MONK_DIAGNOSTICS_HELPER_TIMEOUT=1 \
    MONK_TEST_DIAGNOSTICS_MODE=ok \
    "$repo/$hook")"
  [ "$output" = "$expected" ]
}

run_bounded_case hooks/monk-diagnostics.sh ''
run_bounded_case plugins/monk/hooks/monk-diagnostics.sh ''
run_bounded_case .antigravity-plugin/hooks/monk-diagnostics.sh '{}'

run_healthy_case hooks/monk-diagnostics.sh '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
run_healthy_case plugins/monk/hooks/monk-diagnostics.sh '{"hookSpecificOutput":{"hookEventName":"PostToolUse"}}'
run_healthy_case .antigravity-plugin/hooks/monk-diagnostics.sh '{}'

cmp "$repo/hooks/monk-diagnostics.sh" "$repo/plugins/monk/hooks/monk-diagnostics.sh"
cmp "$repo/hooks/monk-diagnostics.ps1" "$repo/plugins/monk/hooks/monk-diagnostics.ps1"
sh -n "$repo/hooks/monk-diagnostics.sh" "$repo/plugins/monk/hooks/monk-diagnostics.sh" \
  "$repo/.antigravity-plugin/hooks/monk-diagnostics.sh" "$repo/hooks/monk-diagnostics-codex.sh"

printf '%s\n' 'diagnostics_hook_timeout_status=pass'
