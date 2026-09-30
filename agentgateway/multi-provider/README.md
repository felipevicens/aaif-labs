# One API, Any Provider: lab

Companion manifests for the post **"One API, Any Provider: Switching LLMs
Without Changing Your App"** (A1), the first post of the multi-provider LLM
gateway series.

The lab is one `HTTPRoute` on `/v1/chat/completions` (the path the OpenAI SDKs
call) and one `AgentgatewayBackend` called `llm`. Each scenario re-applies
`llm` with a different provider: httpbun (keyless mock), then OpenAI, then
Gemini, then Anthropic, then OpenAI and Gemini in priority groups. The client,
a `curl` or a 10-line Python app using the OpenAI SDK with `base_url` pointed
at the gateway, never changes. A keyless scenario uses an echo server to show
what agentgateway actually sends to Gemini and Anthropic after translating the
request.

## Layout

```
kind-config.yaml                         # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md              # exact commands, apply order, cleanup
  01-gateway-httpbun-route.yaml          # Scenario 1: gateway, httpbun, backend llm, route (no keys)
  02-openai-backend.yaml                 # Scenario 2: llm -> OpenAI
  03-see-the-translation.yaml            # Scenario 3: echo server shows the translated requests (no keys)
  04-gemini-backend.yaml                 # Scenario 4: llm -> Gemini (x-goog-api-key)
  05-anthropic-backend.yaml              # Scenario 5: llm -> Anthropic (x-api-key, set by the gateway)
  06-provider-groups-openai-first.yaml   # Scenario 6: OpenAI + Gemini in groups, OpenAI first
  07-provider-groups-gemini-first.yaml   # Scenario 6: same, groups swapped
  08-groups-without-eviction.yaml        # Gotcha: group order is not failover (no keys)
scripts/
  setup.sh                               # stands everything up
  teardown.sh                            # kind delete cluster
```

No manifest contains a key or a `${PLACEHOLDER}`. Provider keys go in
Secrets created from your environment with `kubectl create secret`, so every
file can be applied straight from GitHub.

## Quickstart

```sh
cd scripts
./setup.sh
```

That runs the keyless scenarios (1, 3 and the Gotcha demo). With keys, it
also creates the Secrets and applies 2, 4, 5 and 6:

```sh
OPENAI_API_KEY=sk-your-key GEMINI_API_KEY=your-key ANTHROPIC_API_KEY=sk-ant-your-key ./setup.sh
```

Reach the gateway with a port-forward (on kind the `LoadBalancer` Service
stays `<pending>`, there is no load-balancer provider):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh`.

## What's validated and what isn't

- **Every scenario is live-validated** on agentgateway `1.5.0`, Gateway API
  `1.6.0`, kind node `v1.34.0`: twice from scratch, once through the keyless
  path and the manual `kubectl apply` sequence (01 to 08), once through
  `setup.sh` with keys, then the same requests again. Re-validated on
  2026-09-30 after adding Anthropic, twice from scratch. Same results both times, with `curl` and with
  the OpenAI Python SDK (`openai` 2.37.0).
- **Real providers:** OpenAI `gpt-4o-mini`, Gemini `gemini-3.5-flash-lite`
  and Anthropic `claude-haiku-4-5` answered through the gateway, all three in
  OpenAI's response shape. Scenario 3 shows the exact request agentgateway
  sends to Gemini and Anthropic.
- **Streaming:** `stream=True` with the OpenAI Python SDK works against all
  three providers, returned as OpenAI `chat.completion.chunk` events. Tool
  calls are not tested.
- **Anthropic `max_tokens`:** Anthropic requires it. When the client sends
  none, the gateway sends `4096` (seen in echo's log).
- **Gemini auth:** by default, 1.5.0 only moves a Gemini key to
  `x-goog-api-key` when it starts with `AIza`. A key starting with `AQ.`
  returned `401` with the default auth and `200` with
  `auth.location.header.name: x-goog-api-key`, which `04` and `05`/`06` set.
  Not tested with an `AIza` key.
- **Failure paths tested:** Gemini default auth (`401`), group order without
  eviction (`500` five times, group 1 never used), nonexistent client model
  (silently replaced by the backend's model), `spec.ai.policies` (rejected by
  the API server).

## A note on the environment

The lab was validated on a normal Docker + kind install. Two things came from
the local network, not from the lab, and are not in any manifest:

- **TLS interception.** On a network that intercepts outbound TLS (common on
  corporate networks), the gateway pod doesn't trust the proxy's certificate
  and calls fail with `upstream call failed: Connect: invalid peer
  certificate: UnknownIssuer`. Mount a CA bundle that includes the proxy's CA
  into the `agentgateway-proxy` Deployment and set `SSL_CERT_FILE` to it.
- **HTTP proxy variables.** If your shell sets `HTTP_PROXY`, the OpenAI Python
  SDK sends `localhost:8080` to that proxy. Run the app with
  `NO_PROXY=localhost,127.0.0.1`.

See `PLAN.md` (private repo) for the full decision log.
