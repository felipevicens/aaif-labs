#!/usr/bin/env bash
# Removes everything setup.sh and the scenarios created: running sandboxes,
# the server process, the MCP registration and the three uv tools.
#
# Sandboxes are killed through the API first, so the server also removes their
# egress sidecars. Then any container still labelled opensandbox.io/id is
# removed, in case the server was already gone. Nothing else on your Docker is
# touched. The pulled images stay; `docker image rm` them if you want the space.
#
# ~/.sandbox.toml and ~/.opensandbox/ are kept so a second run reuses the same
# API key. Pass --purge to delete them too.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

if command -v osb >/dev/null && curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
  for id in $(osb sandbox list -o json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
for s in (d.get("items", d) if isinstance(d, dict) else d):
    print(s["id"])' 2>/dev/null); do
    osb sandbox kill "$id" >/dev/null && echo "killed sandbox $id"
  done
fi

if [ -f "$HOME/.opensandbox/server.pid" ]; then
  kill "$(cat "$HOME/.opensandbox/server.pid")" 2>/dev/null && echo "server stopped" || true
  rm -f "$HOME/.opensandbox/server.pid"
fi

leftover=$(docker ps -aq --filter label=opensandbox.io/id)
[ -n "$leftover" ] && docker rm -f $leftover >/dev/null && echo "removed leftover containers"

command -v claude >/dev/null && claude mcp remove opensandbox 2>/dev/null || true

for t in opensandbox-server opensandbox-cli opensandbox-mcp; do
  uv tool uninstall "$t" >/dev/null 2>&1 && echo "uninstalled $t" || true
done

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.sandbox.toml" "$HOME/.opensandbox"
  echo "removed ~/.sandbox.toml and ~/.opensandbox"
fi
