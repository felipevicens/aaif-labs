# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-a2a-handshake --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system \
  --version 1.5.0 agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Apply order for the manifests in this folder:

1. `02-agent-a.yaml` — creates the `a2a-handshake` namespace and the
   "Hello World Agent", a real `a2a-sdk==1.1.2` server (protocol v1.0
   only), embedded via ConfigMap like every other small tool server in
   this series.
2. `03-agent-b.yaml` — "Loud Agent", same shape, deliberately different
   output (uppercased) so a routing mistake between the two is obvious.
3. `01-gateway-and-backends.yaml` — Gateway, two `AgentgatewayBackend`
   (`spec.a2a: {host, port}`, one per agent), two `HTTPRoute`s each with
   a `URLRewrite` filter stripping its own path prefix.
4. `04-rate-limit-policy.yaml` — `AgentgatewayPolicy` with
   `traffic.rateLimit.local`, stacked on agent-b's `HTTPRoute` only.
   Apply this after `setup.sh` finishes, by hand, so the before/after is
   visible and agent-a stays reachable as a control.

Reach the gateway with one port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Talk to the gateway with `scripts/a2a_client.py`, a minimal stdlib-only
JSON-RPC client (no `a2a-sdk` needed on the client side) that gets three
things right a bare HTTP client wouldn't by default: the real method
names (`SendMessage` / `SendStreamingMessage`, not `message/send`), the
real message field (`parts`, not `content`), and the `A2A-Version: 1.0`
header (silently assumed to be `0.3` if omitted, which this SDK's handler
then rejects).

```sh
# Scenario 1: routing + agent-card rewrite
python3 scripts/a2a_client.py card http://localhost:8080/a2a/agent-a
python3 scripts/a2a_client.py card http://localhost:8080/a2a/agent-b

# Scenario 2: task call, non-streaming
python3 scripts/a2a_client.py send http://localhost:8080/a2a/agent-a "hi there"
python3 scripts/a2a_client.py send http://localhost:8080/a2a/agent-b "hi there"

# Scenario 3: task call, streaming (SSE)
python3 scripts/a2a_client.py stream http://localhost:8080/a2a/agent-a "hi there"

# Scenario 4: stack a generic traffic policy on agent-b only
kubectl apply -f manifests/04-rate-limit-policy.yaml
./scripts/fire_requests.sh 10
python3 scripts/a2a_client.py send http://localhost:8080/a2a/agent-a "hi there"   # control: still fine
```

Cleanup:

```sh
kind delete cluster --name agentgateway-a2a-handshake
```
