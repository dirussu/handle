#!/usr/bin/env python3
"""Dependency-free fake MCP server for Akari's __mcptest__ harness.

Speaks newline-delimited JSON-RPC over stdio (the MCP stdio transport) and
implements the minimum surface: initialize, tools/list (echo / save_note /
read_env / add_numbers), and tools/call. Deterministic and offline — the
harness floor for MCPService, the routing path, and keychain-env resolution
before any real community server is wired in.
"""
import json
import os
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue

    mid = msg.get("id")
    method = msg.get("method")

    if method == "initialize":
        # Echo the client's protocol version back — always compatible.
        pv = msg.get("params", {}).get("protocolVersion", "2025-03-26")
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": pv,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "akari-fake-server", "version": "1.0"},
        }})
    elif method == "tools/list":
        # THREE tools so the routing path (prefilter -> select-by-index) has a
        # real choice to make, deterministically and offline.
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {
                "name": "echo",
                "description": "Echo the given text back, prefixed with 'echo: '.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"text": {"type": "string", "description": "Text to echo"}},
                    "required": ["text"],
                },
            },
            {
                "name": "save_note",
                "description": "Save a short note for later.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string", "description": "The note text"},
                        "title": {"type": "string", "description": "Optional note title"},
                    },
                    "required": ["text"],
                },
            },
            {
                "name": "read_env",
                "description": "Read an environment variable of this server process by name.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"name": {"type": "string", "description": "Variable name"}},
                    "required": ["name"],
                },
            },
            {
                "name": "add_numbers",
                "description": "Add two numbers and return the sum.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "a": {"type": "number", "description": "First number"},
                        "b": {"type": "number", "description": "Second number"},
                    },
                    "required": ["a", "b"],
                },
            },
        ]}})
    elif method == "tools/call":
        params = msg.get("params", {})
        args = params.get("arguments", {}) or {}
        name = params.get("name")
        if name == "save_note":
            text = "note saved: " + str(args.get("text", ""))
        elif name == "read_env":
            text = os.environ.get(str(args.get("name", "")), "(unset)")
        elif name == "add_numbers":
            text = str(args.get("a", 0) + args.get("b", 0))
        else:
            text = "echo: " + str(args.get("text", ""))
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": text}],
            "isError": False,
        }})
    elif mid is not None:
        # Any other REQUEST (ping etc.) gets an empty success; notifications
        # (no id, e.g. notifications/initialized) are ignored.
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
