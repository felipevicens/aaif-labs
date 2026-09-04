#!/usr/bin/env python3
"""Minimal MCP Streamable HTTP client for this lab.

Talks to agentgateway's own aggregated /mcp endpoint, same pattern every
other lab's client in this series uses.

Usage:
  python3 mcp_client.py list                          # tool names only
  python3 mcp_client.py describe                       # names + full descriptions
  python3 mcp_client.py call <tool-name>                # call with no arguments
  python3 mcp_client.py call <tool-name> '<json-args>'  # call with arguments

Only needs `pip install mcp` (the official Python MCP SDK).
"""
import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.exceptions import MCPError

URL = "http://localhost:8080/mcp"


async def list_tools():
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            for tool in result.tools:
                print(tool.name)


async def describe_tools():
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            for tool in result.tools:
                print(f"--- {tool.name} ---")
                print(tool.description or "(no description)")
                print()


async def call_tool(name: str, arguments: dict):
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            try:
                result = await session.call_tool(name, arguments)
            except MCPError as e:
                print(f"ERROR: {e.error.code} {e.error.message}")
                return
            for item in result.content:
                text = getattr(item, "text", str(item))
                print(text)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "list" and len(sys.argv) == 2:
        asyncio.run(list_tools())
    elif sys.argv[1] == "describe" and len(sys.argv) == 2:
        asyncio.run(describe_tools())
    elif sys.argv[1] == "call" and len(sys.argv) in (3, 4):
        tool_name = sys.argv[2]
        args = json.loads(sys.argv[3]) if len(sys.argv) == 4 else {}
        asyncio.run(call_tool(tool_name, args))
    else:
        print(__doc__)
        sys.exit(1)
