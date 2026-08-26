# HTTP API

Bonodis has an HTTP JSON API for environments where you don't want a Redis client library. It runs on the `--metrics-port` listener (loopback only).

## Enable it

```
bonodis --bind 127.0.0.1 --port 6379 --protected-mode no --metrics-port 9090
```

The HTTP API is now at `http://127.0.0.1:9090`.

## Run commands

### Single command

```
curl -s http://127.0.0.1:9090/api -d '{"argv":["SET","mykey","myvalue"]}'
# {"ok":true,"result":"OK"}

curl -s http://127.0.0.1:9090/api -d '{"argv":["GET","mykey"]}'
# {"ok":true,"result":"myvalue"}
```

### Pipeline (multiple commands)

```
curl -s http://127.0.0.1:9090/api/pipeline -d '{
  "commands": [
    ["SET", "a", "1"],
    ["SET", "b", "2"],
    ["MGET", "a", "b"]
  ]
}'
```

### Ping

```
curl -s http://127.0.0.1:9090/api/ping
# {"ok":true,"result":"PONG"}
```

## Authentication

If `--requirepass` is set, pass the password in one of three ways:

```
# JSON body field
curl -s http://127.0.0.1:9090/api -d '{"auth":"secret","argv":["GET","k"]}'

# Header
curl -s -H "X-Bonodis-Auth: secret" http://127.0.0.1:9090/api -d '{"argv":["GET","k"]}'

# Bearer token
curl -s -H "Authorization: Bearer secret" http://127.0.0.1:9090/api -d '{"argv":["GET","k"]}'
```

## Brain API

Convenience endpoints for agent memory operations:

```
# Store a memory
curl -s http://127.0.0.1:9090/brain/remember -d '{
  "ns": "mem", "id": "p1", "text": "user prefers dark mode",
  "vector": [0.1, 0.2, 0.3]
}'

# Recall memories
curl -s http://127.0.0.1:9090/brain/recall -d '{
  "ns": "mem", "query": "dark theme", "k": 5,
  "vector": [0.1, 0.2, 0.3]
}'

# Record conversation
curl -s http://127.0.0.1:9090/brain/say -d '{
  "session": "chat", "role": "user", "content": "make it darker"
}'

# Get conversation
curl -s "http://127.0.0.1:9090/brain/context?session=chat"

# Pack context
curl -s http://127.0.0.1:9090/brain/pack -d '{
  "session": "chat", "ns": "mem", "query": "dark", "k": 8
}'

# Cache
curl -s http://127.0.0.1:9090/brain/cache -d '{"hash":"abc","response":"cached data"}'
curl -s "http://127.0.0.1:9090/brain/cache?hash=abc"
```

## TURN endpoint

```
curl -s http://127.0.0.1:9090/turn -d '{
  "session": "{d}sess", "ns": "{d}mem", "query": "dark mode"
}'
```

## Prometheus metrics

```
curl -s http://127.0.0.1:9090/metrics
```

Standard text format. Also available via the `METRICS` RESP command.

## MCP (Model Context Protocol)

JSON-RPC 2.0 over HTTP POST. Not Streamable HTTP, not SSE, not stdio.

```
# Initialize
curl -s http://127.0.0.1:9090/mcp -d '{
  "jsonrpc": "2.0", "id": 1, "method": "initialize"
}'

# List tools
curl -s http://127.0.0.1:9090/mcp -d '{
  "jsonrpc": "2.0", "id": 2, "method": "tools/list"
}'

# Call a tool
curl -s http://127.0.0.1:9090/mcp -d '{
  "jsonrpc": "2.0", "id": 3, "method": "tools/call",
  "params": {"name": "turn", "arguments": {"session": "{d}sess", "ns": "{d}mem"}}
}'
```

## Response format

All JSON responses follow:

```json
{"ok": true, "result": "..."}
{"ok": false, "error": "ERR ..."}
```

Arrays and nested RESP become JSON arrays.

## Play page

`GET /play` serves an HTML form for running commands in the browser. Useful for debugging.
