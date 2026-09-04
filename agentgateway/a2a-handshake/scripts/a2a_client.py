#!/usr/bin/env python3
"""Minimal A2A protocol v1.0 client. Stdlib only (urllib), no a2a-sdk on
the client side — the point is to show the raw wire protocol, the same
reason every MCP post in this series sometimes drops to raw curl for the
simple cases.

Three things a bare HTTP client has to get right that the a2a-sdk hides:
  1. The JSON-RPC method name is `SendMessage` / `SendStreamingMessage`
     (proto-derived CamelCase), not the `message/send`-style naming that
     belongs to A2A's separate REST binding.
  2. The message payload's text goes in `parts: [{"text": "..."}]`, not
     `content`.
  3. The `A2A-Version` HTTP header selects the protocol version per
     request. Omit it and this SDK version silently assumes v0.3, then
     fails with a confusing -32009 "version not supported" error that has
     nothing to do with the request body itself. Always send
     `A2A-Version: 1.0` explicitly.
All three were found by running the real published a2a-sdk against real
sample code, not by reading the docs.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request


def _post(url: str, method: str, text: str):
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": {
                "message": {
                    "role": "ROLE_USER",
                    "parts": [{"text": text}],
                    "messageId": "msg-1",
                }
            },
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/",
        data=body,
        headers={
            "Content-Type": "application/json",
            "A2A-Version": "1.0",
        },
        method="POST",
    )
    return urllib.request.urlopen(req)


def cmd_card(base_url: str) -> None:
    url = base_url.rstrip("/") + "/.well-known/agent-card.json"
    with urllib.request.urlopen(url) as resp:
        print(json.dumps(json.load(resp), indent=2))


def cmd_send(base_url: str, text: str) -> None:
    with _post(base_url, "SendMessage", text) as resp:
        print(json.dumps(json.load(resp), indent=2))


def cmd_stream(base_url: str, text: str) -> None:
    with _post(base_url, "SendStreamingMessage", text) as resp:
        for raw_line in resp:
            line = raw_line.decode().strip()
            if not line:
                continue
            if line.startswith("data:"):
                line = line[len("data:") :].strip()
            print(json.dumps(json.loads(line), indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["card", "send", "stream"])
    parser.add_argument("url", help="Agent base URL, e.g. http://localhost:8080/a2a/agent-a")
    parser.add_argument("text", nargs="?", default="hi there")
    args = parser.parse_args()

    if args.action == "card":
        cmd_card(args.url)
    elif args.action == "send":
        cmd_send(args.url, args.text)
    else:
        cmd_stream(args.url, args.text)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)
