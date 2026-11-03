# Graph, facts, and leases

Bonodis has built-in commands for directed edges, subject-predicate-object triples, confidence scores, and single-holder leases. All of these are same-shard only -- keys must share a hash tag.

## Edges

Create a directed edge between two keys:

```
RELATE {bot}user {bot}prefs "settings"
RELATE {bot}user {bot}history "viewed"
```

Query:

```
NEIGHBORS {bot}user
# {bot}prefs, {bot}history

PATH {bot}user {bot}prefs
# {bot}user -> {bot}prefs
```

Remove:

```
UNRELATE {bot}user {bot}prefs
```

`PATH` does BFS, capped at 6 hops.

## Facts (triples)

Store subject-predicate-object triples:

```
FACT ADD {bot}alice likes "dark mode"
FACT ADD {bot}alice uses "vim"
FACT ADD {bot}alice speaks "python"
```

Query:

```
FACT OF {bot}alice
# likes -> dark mode, uses -> vim, speaks -> python

FACT WHO {bot}alice likes
# dark mode
```

Remove:

```
FACT DEL {bot}alice uses "vim"
```

## Beliefs and tensions

`BELIEVE` is `FACT ADD` with a confidence score (0-100):

```
BELIEVE {bot}alice prefers "tabs" 80
BELIEVE {bot}alice prefers "spaces" 60
```

`TENSIONS` finds predicates where a key has multiple objects -- potential contradictions:

```
TENSIONS {bot}alice
# prefers -> tabs (80), spaces (60)
```

## ASK

Query interface that combines facts and edges:

```
ASK {bot}alice OF          # same as FACT OF
ASK {bot}alice WHO likes   # objects for a predicate, with scores
ASK {bot}alice QUERY "vim" # token overlap search on facts and edges
ASK {bot}alice HOPS 2      # BFS on outgoing edges, 2 hops deep
```

## WHY

Shows edges, facts, and confidence scores for a key in one call:

```
WHY {bot}alice
```

## Focus list

Per-session attention tracking. `ATTEND` prepends a key to a 24-item list:

```
ATTEND {bot}sess {bot}alice
ATTEND {bot}sess {bot}prefs
FOCUS {bot}sess
# {bot}prefs, {bot}alice
```

The list is capped at 24. Oldest entries fall off. `TURN` includes the focus list in its output.

## Budget / Spend

Integer counter that refuses to go below zero:

```
BUDGET {bot}sess 1000
SPEND {bot}sess 200
# :800
SPEND {bot}sess 900
# -ERR budget exhausted
```

`TURN` includes the remaining budget.

## Leases and Fenced Distributed Locks (`LOCK`)

Simple single-holder locks with a TTL (`LEASE`):

```
LEASE {bot}lock 30     # acquire for 30 seconds
# :1 (acquired)

LEASE {bot}lock 30     # someone else tries
# :0 (already held)

LEASED {bot}lock       # check
# :1

UNLEASE {bot}lock      # release early
```

For production distributed locking with owner verification and monotonic fencing tokens (protecting against GC pauses and split-brain), use `LOCK`:

```
# Returns [acquired (1|0), fencing_token, pttl_ms]
LOCK ACQUIRE resource:1 workerA 5000
# 1) (integer) 1
# 2) (integer) 1
# 3) (integer) 5000

# Renew only if owned by workerA (optional fencing token check)
LOCK RENEW resource:1 workerA 8000 1
# :1

# Release only if owned by workerA
LOCK RELEASE resource:1 workerA 1
# :1

# Inspect current owner, fencing token, and remaining PTTL
LOCK INFO resource:1
```

## Native Delayed & Retryable Job Queues (`QUEUE.*`)

Built-in priority job queue with delayed execution, visibility timeouts, retry budgets, and a Dead-Letter Queue (DLQ):

```
# Push jobs with optional DELAY (ms), PRIORITY (higher = first), and MAXRETRIES
QUEUE.PUSH q:jobs j1 '{"task":"email"}' PRIORITY 1 MAXRETRIES 2
QUEUE.PUSH q:jobs j2 '{"task":"urgent"}' PRIORITY 10 DELAY 0 MAXRETRIES 2

# Pop highest-priority ready job with a 30s visibility window
# Returns [job_id, payload, attempt_number]
QUEUE.POP q:jobs worker1 VISIBILITY 30000

# Acknowledge completion
QUEUE.ACK q:jobs j2

# Negative-acknowledge (re-queues immediately or after DELAY ms; moves to DLQ if attempts > maxretries)
QUEUE.NACK q:jobs j1 DELAY 1000

# Inspect, retry, or purge the Dead-Letter Queue
QUEUE.DLQ q:jobs LIST
QUEUE.DLQ q:jobs RETRY j1
QUEUE.DLQ q:jobs PURGE

# Queue state counts (ready, delayed, inflight, dlq, total)
QUEUE.STATS q:jobs
```

## Native Full-Text & Secondary Indexing (`FT.*`)

RediSearch-compatible secondary indexing over `HASH` and `JSON` documents on the shard:

```
FT.CREATE idx:books ON HASH PREFIX 1 book: SCHEMA title TEXT genre TAG price NUMERIC SORTABLE
HSET book:1 title "Systems Programming in Mako" genre "tech,systems" price 45
HSET book:2 title "Distributed Databases" genre "tech,db" price 60

# Search by tag, numeric range, and text with sorting
FT.SEARCH idx:books "@genre:{tech} @price:[40 70]" SORTBY price DESC NOCONTENT
FT.INFO idx:books
FT._LIST
FT.DROPINDEX idx:books
```

## Hash tag requirement

All these commands require same-slot keys. Use `{tag}` to ensure keys hash together:

```
# These all share the hash tag "bot"
{bot}alice
{bot}prefs
{bot}sess
{bot}lock
```

Without hash tags, keys may land on different shards and the commands will return `CROSSSLOT`.
