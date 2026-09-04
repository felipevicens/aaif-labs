#!/usr/bin/env python3
"""Minimal MCP Streamable HTTP client for this lab.

Talks to agentgateway's own aggregated /mcp endpoint, same pattern every
other lab's client in this series uses. Unlike D1-D4, this one can send a
Bearer token, since that's the entire point of this lab.

Usage:
  python3 mcp_client.py list                              # no token
  python3 mcp_client.py list --token <jwt>                 # with a token
  python3 mcp_client.py call <tool-name> [<json-args>] [--token <jwt>]

Only needs `pip install mcp` (the official Python MCP SDK).
"""
import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared._httpx_utils import create_mcp_http_client
from mcp.shared.exceptions import MCPError

URL = "http://localhost:8080/mcp"


def extract_token(argv: list[str]) -> tuple[list[str], str | None]:
    if "--token" in argv:
        i = argv.index("--token")
        token = argv[i + 1]
        return argv[:i] + argv[i + 2 :], token
    return argv, None


def make_http_client(headers: dict):
    return create_mcp_http_client(headers) if headers else None


async def list_tools(headers: dict):
    async with streamable_http_client(URL, http_client=make_http_client(headers)) as (read, write):
        async with ClientSession(read, write) as session:
            try:
                await session.initialize()
            except MCPError as e:
                print(f"ERROR: {e.error.code} {e.error.message}")
                return
            result = await session.list_tools()
            for tool in result.tools:
                print(tool.name)


async def call_tool(name: str, arguments: dict, headers: dict):
    async with streamable_http_client(URL, http_client=make_http_client(headers)) as (read, write):
        async with ClientSession(read, write) as session:
            try:
                await session.initialize()
                result = await session.call_tool(name, arguments)
            except MCPError as e:
                print(f"ERROR: {e.error.code} {e.error.message}")
                return
            for item in result.content:
                text = getattr(item, "text", str(item))
                print(text)


if __name__ == "__main__":
    argv, token = extract_token(sys.argv[1:])
    headers = {"Authorization": f"Bearer {token}"} if token else {}

    if len(argv) == 1 and argv[0] == "list":
        try:
            asyncio.run(list_tools(headers))
        except Exception as e:
            print(f"ERROR: {e}")
    elif len(argv) >= 2 and argv[0] == "call":
        tool_name = argv[1]
        args = json.loads(argv[2]) if len(argv) == 3 else {}
        try:
            asyncio.run(call_tool(tool_name, args, headers))
        except Exception as e:
            print(f"ERROR: {e}")
    else:
        print(__doc__)
        sys.exit(1)
