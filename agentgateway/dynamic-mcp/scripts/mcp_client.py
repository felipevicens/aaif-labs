#!/usr/bin/env python3
"""Minimal MCP Streamable HTTP client for this lab.

Talks to agentgateway's own aggregated /mcp endpoint (not to any backend
target directly), same as the tool-federation (D1) lab's client.

Usage:
  python3 mcp_client.py list              # list every tool the selector currently sees
  python3 mcp_client.py call <tool-name>  # call one tool, no arguments

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
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "list":
        asyncio.run(list_tools())
    elif sys.argv[1] == "call" and len(sys.argv) == 3:
        asyncio.run(call_tool(sys.argv[2]))
    else:
        print(__doc__)
        sys.exit(1)
