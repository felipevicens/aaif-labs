# Install + run commands

Exact commands used to stand up the environment this post was tested against:
one Linux host with Docker Engine, no Kubernetes. Everything runs on
`localhost`. `scripts/setup.sh` does steps 1 to 3 for you.

## 1. Install OpenSandbox 1.2.0

```sh
uv tool install opensandbox-server==1.2.0
uv tool install opensandbox-cli==1.2.0
uv tool install opensandbox-mcp==1.2.0
export PATH="$HOME/.local/bin:$PATH"
```

## 2. Generate and edit the config

```sh
opensandbox-server init-config ~/.sandbox.toml --example docker
```

Three edits on top of the generated file:

```toml
[server]
api_key = "<run: openssl rand -hex 16>"   # without it the server won't start non-interactively

[runtime]
execd_image = "opensandbox/execd:release-1.2.0"   # example ships v1.1.0: osb output loses newlines

[egress]
image = "opensandbox/egress:release-1.2.0"        # example ships v1.1.7
mode = "dns+nft"                                  # Credential Vault (scenario 3) requires it
```

Leave `no_new_privileges = true` as generated.

## 3. Start the server

```sh
opensandbox-server --config ~/.sandbox.toml
curl -s http://127.0.0.1:8080/health   # {"status":"healthy"}
```

Then, in every terminal you use for the scenarios:

```sh
export OPEN_SANDBOX_API_KEY=<the api_key from step 2>
export OPEN_SANDBOX_DOMAIN=localhost:8080
export OPEN_SANDBOX_PROTOCOL=http
```

`osb`, the Python SDK and `opensandbox-mcp` all read these three.

## Run order

1. `scripts/01-first-sandbox.sh`: Scenario 1, no key.
2. `scripts/02-mcp-add.sh`: Scenario 2. Run it from the folder you'll start
   Claude Code in (the MCP entry is scoped to that folder). Then start `claude`
   there and ask it to test a repo inside a sandbox. To run it headless with
   `claude -p`, add `--allowedTools "mcp__opensandbox"`: in that mode nobody
   can approve the MCP calls, so without the flag Claude Code stops at
   `sandbox_create` and asks for permission. Add
   `--output-format stream-json --verbose > run.jsonl` to keep every tool call;
   the post shows a short Python snippet that prints them from that file.
3. `scripts/03-yolo-with-vault.py`: Scenario 3. Export `ANTHROPIC_API_KEY` (or
   `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL`) first, then:

   ```sh
   uv run --with opensandbox==1.2.0 python scripts/03-yolo-with-vault.py
   ```

## Cleanup

```sh
scripts/teardown.sh            # from the same folder as step 2
scripts/teardown.sh --purge    # also deletes ~/.sandbox.toml and ~/.opensandbox
```

It kills the sandboxes through the API, stops the server, removes any
leftover container labelled `opensandbox.io/id`, removes the `opensandbox` MCP
entry and uninstalls the three tools. Pulled images stay:

```sh
docker image rm opensandbox/execd:release-1.2.0 opensandbox/egress:release-1.2.0 \
  python:3.12-slim python:3.12 node:22-bookworm
```
