"""Scenario 3: Claude Code in YOLO mode, inside a sandbox, without your real key.

Claude Code runs with --dangerously-skip-permissions, so it never asks before
running a command. That is only safe because of two OpenSandbox features:

- A deny-by-default network policy. The sandbox can reach the model API and the
  npm registry, nothing else. Anything the agent (or a malicious package) tries
  to send somewhere else is dropped by the egress sidecar.
- Credential Vault. The sandbox only ever sees a fake key. The egress sidecar
  swaps in the real one on the way out, and only for requests that match the
  binding (host + path). Code inside the sandbox cannot read the real key.

Needs the server config from the setup step ([egress] mode = "dns+nft").

Env vars read on the host (never passed into the sandbox):
  OPEN_SANDBOX_API_KEY   the server's api_key
  ANTHROPIC_API_KEY      for api.anthropic.com (sent as x-api-key), or
  ANTHROPIC_AUTH_TOKEN   for a gateway that wants Authorization: Bearer
  ANTHROPIC_BASE_URL     optional, defaults to https://api.anthropic.com
  ANTHROPIC_MODEL        optional
"""

import os
import sys
from datetime import timedelta
from urllib.parse import urlparse

from opensandbox import SandboxSync
from opensandbox.config import ConnectionConfigSync
from opensandbox.models.sandboxes import (
    Credential,
    CredentialBinding,
    CredentialProxyConfig,
    NetworkPolicy,
    NetworkRule,
    SandboxImageSpec,
)

# Pinned so the post's output stays reproducible.
IMAGE = "node:22-bookworm"
CLAUDE_CODE_VERSION = "2.1.316"

base_url = os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
parsed = urlparse(base_url)
model_host = parsed.hostname
# A gateway can live under a path prefix, so the binding is scoped to
# <prefix>/v1/* instead of a bare /v1/*.
api_paths = [f"{parsed.path.rstrip('/')}/v1/*"]

if os.getenv("ANTHROPIC_AUTH_TOKEN"):
    real_secret = os.environ["ANTHROPIC_AUTH_TOKEN"]
    fake_env = {"ANTHROPIC_AUTH_TOKEN": "fake-token-inside-sandbox"}
    auth = {"type": "bearer", "credential": "model-api"}
else:
    real_secret = os.environ["ANTHROPIC_API_KEY"]
    fake_env = {"ANTHROPIC_API_KEY": "fake-key-inside-sandbox"}
    auth = {"type": "apiKey", "name": "x-api-key", "credential": "model-api"}

sandbox_env = {"ANTHROPIC_BASE_URL": base_url, **fake_env}
if os.getenv("ANTHROPIC_MODEL"):
    sandbox_env["ANTHROPIC_MODEL"] = os.environ["ANTHROPIC_MODEL"]

os.environ.setdefault("OPEN_SANDBOX_DOMAIN", "localhost:8080")
# The SDK reads OPEN_SANDBOX_API_KEY and OPEN_SANDBOX_DOMAIN by itself.
connection = ConnectionConfigSync(protocol="http")


def run(sandbox, cmd):
    print(f"\n$ {cmd}")
    result = sandbox.commands.run(cmd)
    # Each chunk already ends with its own newline.
    out = "".join(p.text for p in result.logs.stdout)
    err = "".join(p.text for p in result.logs.stderr)
    if out:
        print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)
    if result.exit_code:
        print(f"[exit {result.exit_code}]")
    return result


sandbox = SandboxSync.create(
    image=SandboxImageSpec(IMAGE),
    timeout=timedelta(minutes=20),
    env=sandbox_env,
    connection_config=connection,
    network_policy=NetworkPolicy(
        defaultAction="deny",
        egress=[
            NetworkRule(action="allow", target=model_host),
            NetworkRule(action="allow", target="registry.npmjs.org"),
        ],
    ),
    credential_proxy=CredentialProxyConfig(enabled=True),
)
print("sandbox:", sandbox.id)

# Same request before and after the vault exists. The sandbox sends its fake
# key both times; only the sidecar knows the real one.
if "ANTHROPIC_AUTH_TOKEN" in fake_env:
    probe_auth = '-H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN"'
else:
    probe_auth = '-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01"'
probe = (
    f"curl -sS -m 20 -o /dev/null -w 'POST /v1/messages -> %{{http_code}}\\n' "
    f"{probe_auth} -H 'content-type: application/json' "
    "-d '{\"model\":\"claude-haiku-5-5\",\"max_tokens\":8,"
    "\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' "
    "\"$ANTHROPIC_BASE_URL/v1/messages\""
)

try:
    run(sandbox, probe)
    sandbox.credential_vault.create(
        credentials=[Credential(name="model-api", source={"value": real_secret})],
        bindings=[
            CredentialBinding(
                name="model-api",
                match={
                    "schemes": ["https"],
                    "hosts": [model_host],
                    "methods": ["GET", "POST"],
                    "paths": api_paths,
                },
                auth=auth,
            )
        ],
    )

    run(sandbox, probe)

    # What the agent can see: only the fake key.
    run(sandbox, "env | grep ANTHROPIC_ | sed 's/=.*inside-sandbox/=<fake>/'")
    run(sandbox, "env | grep -iE 'CA_CERT|SSL_CERT' || echo 'no CA env vars'")
    # What the agent can reach: the policy drops everything not allowed.
    run(sandbox, "curl -sS -m 10 -o /dev/null -w '%{http_code}\\n' https://example.com || echo 'blocked'")

    run(sandbox, f"npm install -g @anthropic-ai/claude-code@{CLAUDE_CODE_VERSION} --no-audit --no-fund 2>&1 | tail -2")
    run(sandbox, "claude --version")

    task = (
        "Create /work/slugify.js exporting a slugify(text) function, plus "
        "/work/slugify.test.js using node:test with at least 5 cases. "
        "Run the tests with node --test and fix anything that fails. "
        "Finish with a one-line summary of the test result."
    )
    # Claude Code refuses --dangerously-skip-permissions as root, and sandbox
    # commands run as root. The node image ships a plain `node` user, so the
    # agent runs as that user. runuser keeps the sandbox env (the fake key and
    # the base URL); only HOME has to point at the user's own home.
    run(sandbox, "mkdir -p /work && chown node:node /work")
    run(
        sandbox,
        f"cd /work && runuser -u node -- env HOME=/home/node "
        f"claude -p {task!r} --dangerously-skip-permissions --output-format text",
    )
    run(sandbox, "ls -la /work && cd /work && node --test 2>&1 | tail -8")
finally:
    sandbox.kill()
    sandbox.close()
    print("\nsandbox killed")
