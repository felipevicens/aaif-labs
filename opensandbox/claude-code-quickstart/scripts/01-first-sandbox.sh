#!/usr/bin/env bash
# Scenario 1: one sandbox, a few commands, then gone. No model, no key.
#
# osb joins the words after `--` into one shell command, but it quotes each
# word first. So `osb command run ID -- whoami && hostname` sends `&&` as a
# literal argument to whoami. Anything with &&, | or > goes inside sh -c '...'.
set -euo pipefail

SID=$(osb sandbox create --image python:3.12-slim --timeout 30m -o json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "sandbox: $SID"

osb command run "$SID" -- python --version
osb command run "$SID" -- sh -c 'whoami && hostname && head -1 /etc/os-release'

osb file write "$SID" /tmp/hello.py --content 'print("2 + 2 =", 2 + 2)'
osb command run "$SID" -- python /tmp/hello.py

# Install a package inside the sandbox. Your machine never sees it.
osb command run "$SID" -- sh -c 'pip install -q cowsay 2>/dev/null; python -m cowsay -t "hello from the sandbox"'
python3 -c 'import cowsay' 2>&1 | tail -1 || true

osb sandbox kill "$SID"
