#!/usr/bin/env sh
# PostToolUse hook for MANIFEST/MonkScript edits.
# Runs monk-agent analyzer diagnostics after file edits and logs results to
# stderr. Antigravity PostToolUse stdout must be an empty JSON object — results
# cannot be injected back into the conversation from this event type.
#
# Antigravity PostToolUse I/O:
#   stdin:  {"stepIdx":N,"transcriptPath":"...","workspacePaths":[...],...}
#   stdout: {}
#
# All logic lives in `monk-agent hook diagnostics`, so this wrapper depends only
# on the binary the plugin already installs — no jq/curl/awk. Best-effort: if the
# binary is missing we still emit {} and exit 0 so the edit is never blocked.

set -eu

# On Windows the .ps1 sibling owns this hook. A host may spawn .sh hooks in an
# interactive git-bash window (e.g. Cursor on Windows) whose stdin is a TTY,
# where `cat` would block forever. Bow out on Windows-flavored bash, or whenever
# stdin is not a pipe, so we never hang and never double up with the .ps1. Still
# emit the required empty JSON object on stdout.
case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) printf '%s\n' "{}"; exit 0 ;; esac
if [ -t 0 ]; then printf '%s\n' "{}"; exit 0; fi

agent="${MONK_AGENT_PATH:-${MONK_AGENT_INSTALL_DIR:-"$HOME/.monk/bin"}/monk-agent}"
if [ ! -x "$agent" ]; then
  printf '%s\n' "{}"
  exit 0
fi

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

  "$agent" hook diagnostics --format antigravity \
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

# The handler prints diagnostics to stderr and the required {} to stdout.
run_diagnostics_helper || printf '%s\n' "{}"
exit 0
