#!/usr/bin/env python3
"""Minimal MCP Streamable HTTP client for this lab.

Talks to agentgateway's own aggregated /mcp endpoint (not to any backend
target directly). agentgateway is the one translating between this
client's Streamable HTTP and each target's own SSE transport underneath.

Usage:
  python3 mcp_client.py list                       # list all federated tools
  python3 mcp_client.py call <tool-name> <url>      # call one tool with {"url": ...}

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


async def call_tool(name: str, url: str):
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, {"url": url})
            for item in result.content:
                text = getattr(item, "text", str(item))
                print(text[:300])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "list":
        asyncio.run(list_tools())
    elif sys.argv[1] == "call" and len(sys.argv) == 4:
        asyncio.run(call_tool(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__)
        sys.exit(1)
