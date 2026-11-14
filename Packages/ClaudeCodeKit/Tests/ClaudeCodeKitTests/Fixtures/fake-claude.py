#!/usr/bin/env python3
"""Stands in for the claude CLI in tests: speaks the stream-json protocol over stdin/stdout."""
import json
import sys

ASK_PERMISSION = "--permission-prompt-tool" in sys.argv
MCP = "--mcp-config" in sys.argv


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


emit({"type": "system", "subtype": "init", "session_id": "fake-session", "model": "fake-model",
      "cwd": "/tmp", "tools": ["Bash", "Edit"], "permissionMode": "default", "argv": sys.argv[1:]})

turn = 0
for line in sys.stdin:
    message = json.loads(line)
    kind = message.get("type")
    if kind == "control_request":
        request = message["request"]
        emit({"type": "control_response", "response": {
            "subtype": "success", "request_id": message["request_id"],
            "response": {"echo": request.get("subtype")}}})
        continue
    if kind != "user":
        continue
    turn += 1
    text = message["message"]["content"][0]["text"]
    decision = None
    if MCP:
        config = json.loads(sys.argv[sys.argv.index("--mcp-config") + 1])
        server = list(config["mcpServers"].keys())[0]
        emit({"type": "control_request", "request_id": "mcp-list-%d" % turn, "request": {
            "subtype": "mcp_message", "server_name": server, "message": {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}}})
        listed = json.loads(sys.stdin.readline())["response"]["response"]["mcp_response"]["result"]["tools"]
        emit({"type": "control_request", "request_id": "mcp-call-%d" % turn, "request": {
            "subtype": "mcp_message", "server_name": server, "message": {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": listed[0]["name"], "arguments": {"word": text}}}}})
        called = json.loads(sys.stdin.readline())["response"]["response"]["mcp_response"]["result"]
        decision = "tools=%d tool says %s" % (len(listed), called["content"][0]["text"])
    elif ASK_PERMISSION:
        emit({"type": "control_request", "request_id": "perm-%d" % turn, "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "ls"}, "tool_use_id": "toolu_%d" % turn}})
        reply = json.loads(sys.stdin.readline())
        decision = reply["response"]["response"]["behavior"]
    emit({"type": "assistant", "session_id": "fake-session", "parent_tool_use_id": None, "message": {
        "role": "assistant", "content": [
            {"type": "text", "text": "echo: " + text},
            {"type": "tool_use", "id": "toolu_x", "name": "Bash", "input": {"command": "ls"}}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "session_id": "fake-session",
          "result": "decision: %s" % decision, "total_cost_usd": 0.01, "duration_ms": 5, "num_turns": turn,
          "structured_output": {"echo": text} if "--json-schema" in sys.argv else None})
