# Demo JWT signing (Scenario 3)

`mint-demo-jwt.py` makes Scenario 3 reproducible end to end. It signs JWTs the
`jwt-auth` policy accepts, using a **throwaway** RSA key it generates on first
run and saves next to itself as `demo-signing-key.pem` (git-ignored — the
private key is **never committed**).

Only needs Python 3 and `cryptography` (no PyJWT).

```sh
# 1. Apply a jwt-auth policy that trusts your freshly generated demo key
python3 mint-demo-jwt.py --policy | kubectl apply -f -

# 2. Mint a token signed by that same key, and use it
export JWT=$(python3 mint-demo-jwt.py)
curl -X POST http://localhost:8080/llm -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $JWT" -d "$BODY"
```

If the JWT request returns `401 no API Key found`, the `api-key-auth` policy
from the earlier scenarios is still attached — two auth policies compose as a
strict **AND**. Detach it to test the JWT alone:

```sh
kubectl delete agentgatewaypolicy api-key-auth -n agentgateway-system
```

Other modes: `--jwks` prints just the public JWKS. The token carries
`iss: virtual-keys-demo`, `aud: agentgateway`, `sub: alice`, and a long expiry.

`06-jwt-auth-policy.yaml` in the parent folder is a **reference shape only** —
its inline JWKS is a placeholder. Use `--policy` above for a policy that
actually verifies your tokens. Never use this key or these tokens for anything
real; in production point `jwks.remote` at your identity provider.
