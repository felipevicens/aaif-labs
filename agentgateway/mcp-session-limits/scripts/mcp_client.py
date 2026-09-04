#!/usr/bin/env python3
"""Minimal MCP Streamable HTTP client for this lab.

Talks to agentgateway's own aggregated /mcp endpoint, same pattern every
other lab's client in this series uses. The SDK manages the
Mcp-Session-Id handshake internally; this client exists for the
higher-level scenarios. The lower-level, wire-visible session mechanics
are demonstrated with raw curl instead, directly in the post.

Usage:
  python3 mcp_client.py list
  python3 mcp_client.py call ping

Only needs `pip install mcp` (the official Python MCP SDK).
"""
import asyncio
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

URL = "http://localhost:8080/mcp"


async def list_tools():
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            for tool in result.tools:
                print(tool.name)


async def call_tool(name: str):
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, {})
            for item in result.content:
                text = getattr(item, "text", str(item))
                print(text)


if __name__ == "__main__":
    argv = sys.argv[1:]
    if len(argv) == 1 and argv[0] == "list":
        asyncio.run(list_tools())
    elif len(argv) == 2 and argv[0] == "call":
        asyncio.run(call_tool(argv[1]))
    else:
        print(__doc__)
        sys.exit(1)
