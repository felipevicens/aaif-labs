#!/usr/bin/env python3
"""app.py with stream=True: the answer comes back as OpenAI
`chat.completion.chunk` events, whichever provider the backend points at.

Validated against OpenAI, Gemini and Anthropic on agentgateway 1.5.0.
Same requirements as app.py.
"""
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-a-real-key")

stream = client.chat.completions.create(
    model="gpt-4o-mini",
    max_tokens=40,
    stream=True,
    messages=[{"role": "user", "content": "Count from 1 to 10, separated by spaces."}],
)
for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
