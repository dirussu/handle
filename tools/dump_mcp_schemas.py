#!/usr/bin/env python3
"""Dump REAL tool schemas from real community MCP servers.

Spawns each server over stdio (newline-delimited JSON-RPC), completes the
initialize handshake, calls tools/list, and writes everything to
tools/mcp_schemas.json. The schemas feed the 4B fill eval (EVALS.md): the
eval must run against what servers ACTUALLY publish, not hand-written
approximations. Dev-time tool — Akari itself never downloads anything.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "mcp_schemas.json")

SERVERS = {
    # name: argv — official reference servers (Anthropic) + popular community ones.
    "filesystem": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    "memory": ["npx", "-y", "@modelcontextprotocol/server-memory"],
    "everything": ["npx", "-y", "@modelcontextprotocol/server-everything"],
    "sequential-thinking": ["npx", "-y", "@modelcontextprotocol/server-sequential-thinking"],
    "fetch": ["uvx", "mcp-server-fetch"],
    "time": ["uvx", "mcp-server-time"],
    "git": ["uvx", "mcp-server-git"],
}


def rpc(proc, msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def read_response(proc, want_id, timeout=90):
    import select
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        if not ready:
            raise TimeoutError("no response")
        line = proc.stdout.readline()
        if not line:
            raise EOFError("server closed stdout")
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue  # some servers chat on stdout before framing properly
        if msg.get("id") == want_id:
            return msg


def dump(name, argv):
    proc = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True)
    try:
        rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "akari-schema-dump", "version": "1.0"},
        }})
        init = read_response(proc, 1)
        rpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = read_response(proc, 2)["result"]["tools"]
        info = init.get("result", {}).get("serverInfo", {})
        print(f"  {name}: {info.get('name', '?')} {info.get('version', '?')} — {len(tools)} tool(s)")
        return tools
    finally:
        proc.kill()


def main():
    result = {}
    for name, argv in SERVERS.items():
        print(f"dumping {name} …")
        try:
            result[name] = dump(name, argv)
        except Exception as e:  # noqa: BLE001 — a missing runtime shouldn't kill the batch
            print(f"  {name}: FAILED — {e}", file=sys.stderr)
    with open(OUT, "w") as f:
        json.dump(result, f, indent=2)
    total = sum(len(v) for v in result.values())
    print(f"wrote {OUT}: {len(result)} server(s), {total} tool schema(s)")


if __name__ == "__main__":
    main()
