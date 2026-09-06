# Cluster + install walkthrough (I2 — the agctl debugging toolkit)

Everything below ran against a real `kind` cluster, twice, from two
independent clusters built from scratch, plus a third run to capture the
exact literal output quoted in the post. Commands and output are copied
verbatim from that third run.

## 1. Stand up the cluster and install everything

```sh
cd scripts
./setup.sh
```

This creates the `kind` cluster, installs the Gateway API experimental
CRDs, agentgateway `1.5.0`, downloads an `agctl` binary pinned to the same
`1.5.0` release, then applies the httpbun-as-OpenAI backend, the `/chat`
route, and a second `/broken` route pointed at a `Service` with no
matching pods.

## 2. Confirm agctl is version-matched to the control plane

```sh
./agctl version
```

```json
{"version":"1.5.0","commit":"fe6732474a96a0363dfb9822859af4e9bab360fa","buildDate":"2026-08-27T17:16:13Z","runtimeOS":"linux","runtimeArch":"amd64"}
```

```sh
./agctl proxy config all gateway/agentgateway-proxy -n agentgateway-system -o json | jq '.version'
```

```json
{
  "version": "1.5.0",
  "git_revision": "fe6732474a96a0363dfb9822859af4e9bab360fa",
  "rust_version": "1.98.0",
  "build_profile": "release",
  "build_target": "x86_64-unknown-linux-gnu"
}
```

`commit` from `agctl version` and `git_revision` from the running
control plane's own config dump match byte-for-byte, confirming the
binary and the cluster are on the same build.

## 3. Trace a real request

```sh
./agctl proxy trace gateway/agentgateway-proxy -n agentgateway-system \
  --raw --port 8080 -- http://agctl-toolkit.internal/chat \
  -X POST -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
```

No manual `kubectl port-forward` needed: in Kubernetes mode, `agctl`
resolves the proxy pod and opens its own port-forward. This produced 32
events; the full stage sequence and the key event bodies are quoted in
the post itself. Full raw capture: `../../../drafts/agentgateway/agctl-toolkit/`
is the post; the JSONL this walkthrough is built from is not committed
here, since it's just this trace re-run against your own cluster.

## 4. Trace the broken route

```sh
./agctl proxy trace gateway/agentgateway-proxy -n agentgateway-system \
  --raw --port 8080 -- http://agctl-toolkit.internal/broken
```

12 events, no `backendCallStart` or `backendCallResult` at all. The trace
jumps from `policySelection (subBackend)` straight to a `503` response
with `error: "no healthy backends"`. See the post for the full event list.

## 5. Backend health, default vs `--all`

```sh
./agctl proxy config backends gateway/agentgateway-proxy -n agentgateway-system
```

```
TYPE     NAME         NAMESPACE      ENDPOINT  HEALTH  REQUESTS  LATENCY
Backend  httpbun-llm  agctl-toolkit  backend   1.00    1         5.12ms
```

```sh
./agctl proxy config backends gateway/agentgateway-proxy -n agentgateway-system --all
```

```
TYPE     NAME                NAMESPACE            ENDPOINT                                                      HEALTH  REQUESTS  LATENCY
Backend  httpbun-llm         agctl-toolkit        backend                                                       1.00    1         5.12ms
Service  httpbun             agctl-toolkit        httpbun-7d8b69c95f-rzjsz                                      1.00    0
Service  agentgateway        agentgateway-system  agentgateway-6d9f79fd6d-4gdwm                                 1.00    0
Service  agentgateway-proxy  agentgateway-system  agentgateway-proxy-7d5d676db4-59p4d                           1.00    0
Service  kubernetes          default              discovery.k8s.io/EndpointSlice/default/kubernetes/172.18.0.2  1.00    0
Service  kube-dns            kube-system          coredns-66bc5c9577-52dfl                                      1.00    0
Service  kube-dns            kube-system          coredns-66bc5c9577-fvzzq                                      1.00    0
```

One row without `--all` (only the backend that actually took traffic),
seven with it (every `Service` agentgateway's own discovery layer knows
about across the whole cluster).

## 6. Runtime log level

```sh
./agctl proxy log gateway/agentgateway-proxy -n agentgateway-system
```

```
current log level is typespec_client_core::http::policies::logging=warn,hickory_server::server::server_future=off,rmcp=warn,info
```

No arguments just prints the current filter string; `--level` or `--set
module=level` change it at runtime, without restarting the pod.

## 7. Tear down

```sh
cd scripts
./teardown.sh
```
