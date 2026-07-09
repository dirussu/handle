#!/usr/bin/env python3
"""Dependency-free fake MCP server for Akari's __mcptest__ harness.

Speaks newline-delimited JSON-RPC over stdio (the MCP stdio transport) and
implements the minimum surface: initialize, tools/list (one `echo` tool), and
tools/call. Deterministic and offline — the harness floor for MCPService before
any real community server is wired in.
"""
import sys
import json


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
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "echo",
            "description": "Echo the given text back, prefixed with 'echo: '.",
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string", "description": "Text to echo"}},
                "required": ["text"],
            },
        }]}})
    elif method == "tools/call":
        args = msg.get("params", {}).get("arguments", {}) or {}
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": "echo: " + str(args.get("text", ""))}],
            "isError": False,
        }})
    elif mid is not None:
        # Any other REQUEST (ping etc.) gets an empty success; notifications
        # (no id, e.g. notifications/initialized) are ignored.
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
