#!/usr/bin/env python3
"""Mints a JWT signed with the keypair gen_keys.py generated, standing in
for "your IdP just issued this after a real login." No network call,
no IdP container: this is what makes the lab keyless.

Usage: mint_token.py <private-key-path> <role1,role2,...> [--sub NAME]
                      [--exp-seconds N] [--wrong-aud] [--wrong-key PATH]
"""
import argparse
import time

import jwt

KID = "jwt-rbac-key-1"
ISSUER = "https://jwt-rbac.aaif-labs.local/"
AUDIENCE = "jwt-rbac-demo"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("private_key_path")
    parser.add_argument("roles", help="comma-separated role list, e.g. engineer or admin")
    parser.add_argument("--sub", default="demo-user")
    parser.add_argument("--exp-seconds", type=int, default=3600)
    parser.add_argument("--wrong-aud", action="store_true", help="sign for a different audience, to test the 401 path")
    args = parser.parse_args()

    with open(args.private_key_path, "rb") as f:
        private_key = f.read()

    now = int(time.time())
    payload = {
        "iss": ISSUER,
        "aud": "some-other-service" if args.wrong_aud else AUDIENCE,
        "sub": args.sub,
        "roles": [r for r in args.roles.split(",") if r],
        "iat": now,
        "exp": now + args.exp_seconds,
    }
    token = jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": KID})
    print(token)


if __name__ == "__main__":
    main()
