#!/usr/bin/env python3
"""Generates a throwaway RSA keypair for this lab and prints the public
half as a JWK Set (JSON), for `jwks.inline` in the AgentgatewayPolicy
manifests. Nothing here is a real credential — it's a fresh keypair
minted for this one cluster run and discarded on teardown, standing in
for "you already have an IdP that publishes a JWKS somewhere."

Usage: gen_keys.py <output-dir>
Writes <output-dir>/private.pem and prints the JWK Set JSON to stdout.
"""
import base64
import json
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KID = "jwt-rbac-key-1"


def b64url_uint(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: gen_keys.py <output-dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with open(f"{out_dir}/private.pem", "wb") as f:
        f.write(private_pem)

    public_numbers = key.public_key().public_numbers()
    jwk = {
        "kty": "RSA",
        "use": "sig",
        "alg": "RS256",
        "kid": KID,
        "n": b64url_uint(public_numbers.n),
        "e": b64url_uint(public_numbers.e),
    }
    print(json.dumps({"keys": [jwk]}))


if __name__ == "__main__":
    main()
