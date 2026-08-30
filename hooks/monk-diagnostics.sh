#!/usr/bin/env sh
# PostToolUse hook for MANIFEST/MonkScript edits.
# Asks local monk-agent for analyzer diagnostics and feeds concise results back
# into Claude Code after template edits.
#
# All logic (path resolution, workspace discovery, the MCP call, and formatting)
# lives in `monk-agent hook diagnostics`, so this wrapper depends only on the
# binary the plugin already installs — no jq/curl/awk. The hook is best-effort:
# a missing binary, missing agent, auth issues, or unavailable analyzer support
# must never block the user's edit, so we always exit 0.

set -eu

# Output shape: "claude" (default, also Cursor) emits a superset; "codex" emits
# ONLY the documented PostToolUse fields (Codex drops output with any unknown
# top-level key). The Codex hook passes `--format codex`; others use the default.
fmt="claude"
if [ "${1:-}" = "--format" ] && [ -n "${2:-}" ]; then fmt="$2"; fi

# On Windows the .ps1 sibling owns this hook. A host may spawn .sh hooks in an
# interactive git-bash window (e.g. Cursor on Windows) whose stdin is a TTY,
# where `cat` would block forever. Bow out on Windows-flavored bash, or whenever
# stdin is not a pipe, so we never hang and never double up with the .ps1.
case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) exit 0 ;; esac
if [ -t 0 ]; then exit 0; fi

agent="${MONK_AGENT_PATH:-${MONK_AGENT_INSTALL_DIR:-"$HOME/.monk/bin"}/monk-agent}"
[ -x "$agent" ] || exit 0

helper_timeout="${MONK_DIAGNOSTICS_HELPER_TIMEOUT:-10}"
case "$helper_timeout" in
  *[!0-9]*|0*) helper_timeout=10 ;;
esac

run_diagnostics_helper() {
  helper_dir="$(mktemp -d "${TMPDIR:-/tmp}/monk-diagnostics.XXXXXX")" || return 1
  helper_input="$helper_dir/input"
  helper_output="$helper_dir/output"
  helper_error="$helper_dir/error"
  helper_timed_out="$helper_dir/timed-out"
  cat >"$helper_input" || { rm -rf "$helper_dir"; return 1; }

  "$agent" hook diagnostics --format "$fmt" \
    <"$helper_input" >"$helper_output" 2>"$helper_error" &
  helper_pid=$!
  (
    sleep "$helper_timeout"
    : >"$helper_timed_out"
    kill -TERM "$helper_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$helper_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!

  if wait "$helper_pid" 2>/dev/null; then
    helper_status=0
  else
    helper_status=$?
  fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ ! -f "$helper_timed_out" ]; then
    cat "$helper_error" >&2
    cat "$helper_output"
  fi
  rm -rf "$helper_dir"
  return "$helper_status"
}

run_diagnostics_helper || exit 0
exit 0
