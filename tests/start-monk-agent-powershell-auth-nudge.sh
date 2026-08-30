#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
image="${MONK_PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}"
docker run --rm "$image" pwsh -NoProfile -Command 'exit 0' >/dev/null
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/home/agent/launcher/run" "$root/install"
printf '#!/bin/sh\nexit 0\n' > "$root/install/monk-agent.exe"; chmod +x "$root/install/monk-agent.exe"
cat > "$root/home/agent/launcher/run/monk-agent.state" <<'STATE'
agent_path=/fixture/install/monk-agent.exe
auth_url=https://auth.monk.io
auth_client_id=UW84YWcJME3buMSLfqLX8IbBsYdNWi47
auth_audience=oaknode.com
autospin_url=wss://api.app.monk.io/autospin/
plugin_version=0.1.58
STATE
cat > "$root/server.py" <<'PY'
import http.server, os
body=os.environ['AUTH_BODY'].encode(); postfile=os.environ['POST_FILE']; port=int(os.environ['PORT'])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path=='/.well-known/oauth-protected-resource': data=(f'{{"resource":"http://127.0.0.1:{port}/mcp"}}').encode()
        elif self.path=='/auth.json': data=body
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        with open(postfile,'a') as f: f.write(self.path+'\n')
        self.send_response(204); self.end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1',port),H).serve_forever()
PY
run_case(){
  name="$1" body="$2" port="$3" expected_posts="$4" expected_msg="$5"
  post="$root/$name.posts"; : > "$post"
  AUTH_BODY="$body" POST_FILE="$post" PORT="$port" python3 "$root/server.py" & srv=$!
  sleep .15
  out=$(timeout 8s docker run --rm --network host -e OS=Windows_NT -e MONK_AGENT_PORT="$port" -e MONK_AGENT_HOST=127.0.0.1 -e MONK_AGENT_SKIP_ENSURE=1 -e MONK_AGENT_INSTALL_DIR=/fixture/install -e MONK_AGENT_HOME=/fixture/home -e HOME=/fixture/user -v "$repo:/repo:ro" -v "$root:/fixture" "$image" pwsh -NoProfile -File /repo/scripts/start-monk-agent.ps1 2>&1 || true)
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
  posts=$(wc -l < "$post"); msgs=$(printf '%s' "$out" | grep -c 'NOT signed in' || true)
  [ "$posts" -eq "$expected_posts" ] || { echo "$name posts=$posts expected=$expected_posts" >&2; exit 1; }
  [ "$msgs" -eq "$expected_msg" ] || { echo "$name messages=$msgs expected=$expected_msg" >&2; exit 1; }
}
run_case unrelated '{"status":"ok"}' 17531 0 0
run_case missing_null '{"signedIn":null}' 17532 0 0
run_case explicit_false '{"signedIn":false}' 17533 1 1
run_case explicit_true '{"signedIn":true}' 17534 0 0
run_case malformed '{not-json' 17535 0 0
echo powershell_auth_nudge_status=pass
