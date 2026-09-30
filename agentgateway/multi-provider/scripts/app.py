#!/usr/bin/env python3
"""The whole app for this lab: the OpenAI SDK, pointed at the gateway.

It never changes across the scenarios. Only the backend `llm` behind the
gateway does. The api_key is fake on purpose: the gateway adds the real
provider key from a Kubernetes Secret.

Needs `pip install openai`. Run it with the port-forward from Scenario 1
open. If your shell sets HTTP_PROXY, run it with
NO_PROXY=localhost,127.0.0.1 so the SDK doesn't send localhost to the proxy.
"""
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-a-real-key")

reply = client.chat.completions.create(
    model="gpt-4o-mini",
    max_tokens=20,
    messages=[{"role": "user", "content": "Say OK"}],
)
print(reply.model, "->", reply.choices[0].message.content)
