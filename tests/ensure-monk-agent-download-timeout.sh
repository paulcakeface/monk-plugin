#!/usr/bin/env sh
# Regression coverage: checksum and archive downloads must carry bounded
# connect and low-speed deadlines so a stalled server cannot consume the host
# SessionStart hook indefinitely.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_bin="$repo_root/tests/fixtures/ensure-monk-agent"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

calls="$work_dir/curl-calls"
: >"$calls"

set +e
PATH="$fixture_bin:$PATH" \
TEST_CURL_CALLS="$calls" \
TEST_CONNECT_TIMEOUT=7 \
TEST_STALL_TIMEOUT=9 \
MONK_AGENT_DOWNLOAD_CONNECT_TIMEOUT=7 \
MONK_AGENT_DOWNLOAD_STALL_TIMEOUT=9 \
MONK_AGENT_DOWNLOAD_BASE=https://downloads.invalid/stable \
MONK_AGENT_INSTALL_DIR="$work_dir/install" \
  "$repo_root/scripts/ensure-monk-agent.sh" >"$work_dir/stdout" 2>"$work_dir/stderr"
status=$?
set -e

[ "$status" -eq 28 ]
[ "$(wc -l <"$calls")" -eq 2 ]
if grep -v ' bounded=1$' "$calls"; then
  echo "monk-agent download was attempted without bounded network deadlines" >&2
  exit 1
fi

[ "$(grep -F -c 'wget -t 1 -T "$download_stall_timeout"' "$repo_root/scripts/ensure-monk-agent.sh")" -eq 2 ]

cmp "$repo_root/scripts/ensure-monk-agent.sh" "$repo_root/plugins/monk/scripts/ensure-monk-agent.sh"
cmp "$repo_root/scripts/ensure-monk-agent.sh" "$repo_root/.antigravity-plugin/scripts/ensure-monk-agent.sh"

printf 'ensure_monk_agent_download_timeout=pass calls=2\n'
