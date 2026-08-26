# Agent memory

How to use Bonodis as the memory layer for an AI agent. This covers storing memories, recalling them, tracking conversation, and assembling a context window -- all in one place, without round-trip orchestration.

## The problem

An AI agent loop typically needs:
1. Store what the user said and what the agent did
2. Recall relevant past interactions when a new message arrives
3. Pack it all into a prompt that fits the model's context window

Most setups bolt this together with Redis + a vector DB + application code that makes 4-5 round-trips per turn. Bonodis does it in one or two calls.

## Setup

Start the server:

```
./bonodis --bind 127.0.0.1 --port 6379 --appendonly yes --dir ./data --protected-mode no
```

All keys for one agent must share a hash tag so they land on the same shard:

```
{myagent}mem     # memory namespace (vector key)
{myagent}sess    # conversation list
```

## Store a memory

```
BRAIN REMEMBER {myagent}mem p1 "user prefers dark mode"
BRAIN REMEMBER {myagent}mem p2 "user is a backend engineer"
BRAIN REMEMBER {myagent}mem p3 "user asked about database sharding"
```

Each memory gets an id (`p1`, `p2`, `p3`) and text. If you have embeddings from your model, append them:

```
BRAIN REMEMBER {myagent}mem p1 "user prefers dark mode" 0.12 0.88 -0.04 0.33
```

## Record conversation

```
BRAIN SAY {myagent}sess user "make the background darker"
BRAIN SAY {myagent}sess assistant "done, switched to dark mode"
```

This is an `RPUSH` of `role<tab>content`. The list grows as the conversation progresses.

## Recall relevant memories

Without embeddings (uses token overlap):

```
BRAIN RECALL {myagent}mem COUNT 5 QUERY "dark theme"
```

With embeddings:

```
BRAIN RECALL {myagent}mem COUNT 5 QUERY "dark theme" 0.10 0.90 -0.02 0.30
```

Returns the top matches ranked by cosine similarity (if floats given) or by how many query tokens appear in the memory text.

## Pack context for the model

```
BRAIN PACK {myagent}sess {myagent}mem QUERY "dark theme"
```

Returns a single text block with sections:

```
# memories
user prefers dark mode
user asked about database sharding

# conversation
user: make the background darker
assistant: done, switched to dark mode
```

Empty sections are omitted. The `# related` section includes edges and facts if any exist (see graph commands).

## TURN: everything in one call

```
TURN {myagent}sess {myagent}mem QUERY "dark theme"
```

Same as `BRAIN PACK` but also prepends budget (if set), focus list (if non-empty), and tensions (if any contradictions exist in the facts). One call, one read, zero orchestration.

## Compact old memories

Over time, memories accumulate duplicates. Compact merges entries whose text overlaps by 60% or more:

```
BRAIN COMPACT {myagent}mem
```

## Automatic context rebuild with REACT

Instead of calling `BRAIN PACK` from your application after every memory write, let the server do it:

```
REACT CREATE auto_ctx {myagent}mem ON WRITE BRAIN COMPACT {myagent}mem | BRAIN PACK {myagent}sess {myagent}mem
```

Now every `BRAIN REMEMBER` to `{myagent}mem` automatically compacts and rebuilds the packed context. Your application just reads the result on the next turn.

## Budget tracking

Set a token/call budget per session:

```
BUDGET {myagent}sess 1000
SPEND {myagent}sess 150
SPEND {myagent}sess 200
SPEND {myagent}sess 700
# -ERR budget exhausted
```

`TURN` includes the remaining budget in its output.

## Python example

```python
import redis

r = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)
tag = "{myagent}"

# store memories
r.execute_command("BRAIN", "REMEMBER", f"{tag}mem", "p1", "user prefers dark mode")
r.execute_command("BRAIN", "REMEMBER", f"{tag}mem", "p2", "user is on macOS")

# record conversation
r.execute_command("BRAIN", "SAY", f"{tag}sess", "user", "how do I enable dark mode?")

# get packed context for your model prompt
ctx = r.execute_command("TURN", f"{tag}sess", f"{tag}mem", "QUERY", "dark mode")
print(ctx)

# use ctx as the system/context portion of your LLM prompt
```

## What Bonodis does not do

Bonodis stores vectors and ranks by cosine. It does not:
- Compute embeddings (your app calls the embedding model)
- Call an LLM (your app sends the packed context to the model)
- Manage prompt templates (that's application logic)

It is a memory store, not an agent framework.
