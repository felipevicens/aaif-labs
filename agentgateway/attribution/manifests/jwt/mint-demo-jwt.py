#!/usr/bin/env python3
"""Mint a demo JWT (and print its JWKS) for the AgentGateway attribution post.

DEMO ONLY. This mints tokens the `jwt-auth` policy accepts, using a throwaway
RSA key kept next to this script. Never reuse this key or these tokens for
anything real.

Usage:
  python3 mint-demo-jwt.py            # print a signed JWT (RS256)
  python3 mint-demo-jwt.py --jwks     # print the public JWKS
  python3 mint-demo-jwt.py --policy   # print the jwt-auth AgentgatewayPolicy YAML,
                                      # with the matching JWKS filled in, ready to
                                      # pipe into `kubectl apply -f -`

The signing key is generated on first run and saved next to this script as
demo-signing-key.pem (git-ignored — never committed). Only depends on
`cryptography` (no PyJWT needed).
"""
import argparse, base64, json, time
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

KEY_PATH = Path(__file__).with_name("demo-signing-key.pem")
KID = "demo-key-1"
ISSUER = "attribution-demo"
AUDIENCE = "agentgateway"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def load_or_create_key() -> rsa.RSAPrivateKey:
    if KEY_PATH.exists():
        return serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    KEY_PATH.write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ))
    return key


def jwks(key: rsa.RSAPrivateKey) -> dict:
    nums = key.public_key().public_numbers()
    n = nums.n.to_bytes((nums.n.bit_length() + 7) // 8, "big")
    e = nums.e.to_bytes((nums.e.bit_length() + 7) // 8, "big")
    return {"keys": [{"kty": "RSA", "n": b64url(n), "e": b64url(e),
                      "use": "sig", "alg": "RS256", "kid": KID}]}


def mint(key: rsa.RSAPrivateKey) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "kid": KID}
    payload = {"iss": ISSUER, "aud": AUDIENCE, "sub": "alice",
               "iat": now, "exp": now + 10 * 365 * 24 * 3600}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     b64url(json.dumps(payload, separators=(",", ":")).encode()))
    sig = key.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
    return signing_input + "." + b64url(sig)


POLICY = """apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: {issuer}
          audiences:
            - {audience}
          jwks:
            inline: |
              {jwks}
"""


def policy(key: rsa.RSAPrivateKey) -> str:
    return POLICY.format(issuer=ISSUER, audience=AUDIENCE,
                         jwks=json.dumps(jwks(key), separators=(",", ":")))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--jwks", action="store_true", help="print the public JWKS")
    g.add_argument("--policy", action="store_true", help="print the jwt-auth policy YAML with the JWKS filled in")
    args = ap.parse_args()
    k = load_or_create_key()
    if args.jwks:
        print(json.dumps(jwks(k), separators=(",", ":")))
    elif args.policy:
        print(policy(k), end="")
    else:
        print(mint(k))
