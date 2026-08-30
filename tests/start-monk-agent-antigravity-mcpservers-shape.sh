#!/usr/bin/env sh
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
root="$(mktemp -d)"
cleanup() { rm -rf "$root"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$root/home/.gemini/config" "$root/home/.monk/agent/launcher/run" "$root/bin"
cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  *auth.json*) printf '%s\n' '{"signedIn":true}' ;;
  *) printf '%s\n' '{"resource":"http://127.0.0.1:7419/mcp"}' ;;
esac
EOF
chmod +x "$root/bin/curl"
cat >"$root/home/.monk/agent/launcher/run/monk-agent.state" <<'EOF'
agent_path=/bin/true
auth_url=https://auth.monk.io
auth_client_id=UW84YWcJME3buMSLfqLX8IbBsYdNWi47
auth_audience=oaknode.com
autospin_url=wss://api.app.monk.io/autospin/
EOF

run_case() {
  name="$1"
  value="$2"
  cfg="$root/home/.gemini/config/mcp_config.json"
  printf '{"mcpServers":%s,"unrelated":{"keep":true}}\n' "$value" >"$cfg"
  HOME="$root/home" \
  MONK_AGENT_HOME="$root/home/.monk" \
  MONK_AGENT_PATH=/bin/true \
  MONK_AGENT_SKIP_SIGNIN_NUDGE=1 \
  PATH="$root/bin:/usr/bin:/bin" \
    "$repo/scripts/start-monk-agent.sh" >"$root/$name.out" 2>"$root/$name.err"
  jq -e '.unrelated.keep == true' "$cfg" >/dev/null
  jq -e '.mcpServers.monk.serverUrl == "http://127.0.0.1:7419/mcp"' "$cfg" >/dev/null
}

run_case string '"legacy-string-value"'
run_case array '[{"legacy":true}]'
run_case null 'null'
run_case object '{"existing":{"serverUrl":"http://127.0.0.1:9000/mcp"}}'

h1="$(sha256sum "$repo/scripts/start-monk-agent.sh" | awk '{print $1}')"
h2="$(sha256sum "$repo/plugins/monk/scripts/start-monk-agent.sh" | awk '{print $1}')"
h3="$(sha256sum "$repo/.antigravity-plugin/scripts/start-monk-agent.sh" | awk '{print $1}')"
[ "$h1" = "$h2" ] && [ "$h1" = "$h3" ]

printf '%s\n' 'antigravity_mcpservers_shape_status=pass string=normalized array=normalized null=normalized object=preserved copies=3'
