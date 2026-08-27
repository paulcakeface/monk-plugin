#!/usr/bin/env sh
# A wedged monk-agent hook helper must not consume Antigravity's 5-second
# PreToolUse budget. The hook should fall back and still deny a direct monk CLI.
set -eu
repo_root="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
hook="$repo_root/.antigravity-plugin/hooks/block-monk.sh"
work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT HUP INT TERM

cat >"$work_dir/hang-agent" <<'AGENT'
#!/usr/bin/env sh
exec sleep 30
AGENT
chmod +x "$work_dir/hang-agent"

cat >"$work_dir/success-agent" <<'AGENT'
#!/usr/bin/env sh
cat >/dev/null
printf '%s\n' '{"decision":"deny","reason":"helper decision"}'
AGENT
chmod +x "$work_dir/success-agent"

payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"monk status"}}}'

printf '%s' "$payload" |
  MONK_AGENT_PATH="$work_dir/hang-agent" \
  MONK_BLOCK_MONK_HELPER_TIMEOUT=1 \
  "$hook" >"$work_dir/hang.out" 2>"$work_dir/hang.err" &
hook_pid=$!

finished=0
for _ in 1 2 3; do
  if ! kill -0 "$hook_pid" 2>/dev/null; then
    finished=1
    break
  fi
  sleep 1
done
if [ "$finished" -ne 1 ]; then
  kill "$hook_pid" 2>/dev/null || true
  wait "$hook_pid" 2>/dev/null || true
  echo "block-monk hook outlived its helper timeout" >&2
  exit 1
fi
wait "$hook_pid"
grep -q '"decision": "deny"' "$work_dir/hang.out"

printf '%s' "$payload" |
  MONK_AGENT_PATH="$work_dir/success-agent" \
  "$hook" >"$work_dir/success.out" 2>"$work_dir/success.err"
grep -q 'helper decision' "$work_dir/success.out"

printf 'block_monk_helper_timeout=pass\n'
