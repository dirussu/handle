#!/usr/bin/env python3
"""A tiny OpenAI-compatible server for testing Akari's OpenAI adapter with no key
and no model: streams the real Chat Completions wire format.

  GET  /v1/models                    -> two fake ids
  POST /v1/chat/completions (stream) -> text deltas; if tools are offered and the last
       user text mentions "calendar" and no tool result is in the history, a chunked
       read_calendar_events tool call instead; a usage chunk with cached_tokens; [DONE].
       The reply text says what it saw: image bytes, tool results, system prompt length.

  python3 tools/fake_openai_server.py 8765
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": "fake-vision-tools"}, {"id": "fake-text-only"}]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        if self.headers.get("Authorization", "").endswith("bad-key"):
            return self._json(401, {"error": {"message": "Incorrect API key provided", "type": "invalid_request_error"}})
        msgs = req.get("messages", [])
        tools = req.get("tools", [])
        system_len = sum(len(m.get("content", "")) for m in msgs if m.get("role") == "system" and isinstance(m.get("content"), str))
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        last_user = next((m for m in reversed(msgs) if m.get("role") == "user"), {})
        text, image_bytes = "", 0
        c = last_user.get("content", "")
        if isinstance(c, str): text = c
        else:
            for part in c:
                if part.get("type") == "text": text += part.get("text", "")
                elif part.get("type") == "image_url": image_bytes += len(part["image_url"]["url"])
        tool_result = next((m.get("content", "") for m in msgs if m.get("role") == "tool"), None)

        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache"); self.end_headers()
        def chunk(obj):
            self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode()); self.wfile.flush(); time.sleep(0.02)
        cid = "chatcmpl-fake"
        if tools and "calendar" in text.lower() and not has_tool_result:
            names = [t["function"]["name"] for t in tools]
            fn = "read_calendar_events" if "read_calendar_events" in names else names[0]
            chunk({"id": cid, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]})
            chunk({"id": cid, "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_fake1", "type": "function", "function": {"name": fn, "arguments": ""}}]}}]})
            chunk({"id": cid, "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": '{"start_iso": "2026-09-22T00:00:00+02:00", '}}]}}]})
            chunk({"id": cid, "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": '"end_iso": "2026-09-22T23:59:59+02:00"}'}}]}, "finish_reason": "tool_calls"}]})
        else:
            # No digits in the canned text: Akari's recipe/MCP select prompts parse an
            # index out of the reply, and "0" would look like a pick.
            yn = lambda b: "yes" if b else "no"
            reply = "FAKE reply (system prompt: %s; image attached: %s; tools offered: %s" % (yn(system_len), yn(image_bytes), yn(tools))
            if tool_result is not None: reply += "; tool result seen: " + "".join(ch for ch in tool_result[:60] if not ch.isdigit())
            reply += ")"
            for word in reply.split(" "):
                chunk({"id": cid, "choices": [{"index": 0, "delta": {"content": word + " "}}]})
            chunk({"id": cid, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        chunk({"id": cid, "choices": [], "usage": {"prompt_tokens": 123, "completion_tokens": 17, "prompt_tokens_details": {"cached_tokens": 100}}})
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()

if __name__ == "__main__":
    print("fake OpenAI server on http://127.0.0.1:%d/v1" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
