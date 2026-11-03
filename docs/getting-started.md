# Getting started

This walks you through installing Bonodis, running it, and talking to it. If you have used Redis before, most of this will look familiar. If you haven't, that's fine too.

## Install Mako

Bonodis is written in Mako. You need the Mako compiler to build it.

```
# macOS
brew install loreste/tap/makori

# Linux (from source)
git clone https://github.com/loreste/mako
cd mako && make install
```

Verify:

```
mako --version
# should print mako 0.7.0 or later
```

## Build Bonodis

```
git clone https://github.com/loreste/bonodis
cd bonodis
mako build ./lib/main.mko -o bonodis
mako build ./cli/main.mko -o bonodis-cli
```

This produces two binaries: `bonodis` (the server) and `bonodis-cli` (the command-line client).

## Start the server

For local development:

```
./bonodis --bind 127.0.0.1 --port 6379 --protected-mode no
```

You should see:

```
info start version=0.14.0
info ready bind=127.0.0.1 port=6379 shards=16
```

The server is running. Open another terminal.

## Talk to it

```
./bonodis-cli PING
# PONG

./bonodis-cli SET greeting "hello world"
# OK

./bonodis-cli GET greeting
# "hello world"

# Or start an interactive REPL session:
./bonodis-cli -i
127.0.0.1:6379> PING
PONG
```

That's it. You have a running data store.

## Use from your language

Bonodis speaks the same protocol as Redis (RESP2). Use any Redis client library.

### Python

```
pip install redis
```

```python
import redis

r = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)

r.set("name", "alice")
print(r.get("name"))  # alice

r.hset("user:1", mapping={"name": "bob", "age": "30"})
print(r.hgetall("user:1"))  # {'name': 'bob', 'age': '30'}

r.lpush("queue", "task1", "task2")
print(r.rpop("queue"))  # task1
```

### Node.js

```
npm install ioredis
```

```javascript
const Redis = require("ioredis");
const r = new Redis(6379, "127.0.0.1");

await r.set("key", "value");
console.log(await r.get("key")); // value
```

### Go

```go
import "github.com/redis/go-redis/v9"

rdb := redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379"})
rdb.Set(ctx, "key", "value", 0)
val, _ := rdb.Get(ctx, "key").Result()
```

## Common operations

### Strings

```
SET user:1:name "Alice"
GET user:1:name
# "Alice"

SET counter 0
INCR counter
INCR counter
GET counter
# "2"

# Set with expiry (60 seconds)
SET session:abc "data" EX 60
TTL session:abc
# 59
```

### Hashes (like a row or object)

```
HSET user:1 name "Alice" age "30" city "Portland"
HGET user:1 name
# "Alice"
HGETALL user:1
# name Alice age 30 city Portland
```

### Lists (queue or stack)

```
RPUSH jobs "send-email" "resize-image" "generate-report"
LPOP jobs
# "send-email"
LLEN jobs
# 2
LRANGE jobs 0 -1
# "resize-image" "generate-report"
```

### Sets

```
SADD tags:post:1 "rust" "database" "open-source"
SISMEMBER tags:post:1 "rust"
# 1
SMEMBERS tags:post:1
# "rust" "database" "open-source"
```

### Sorted sets (ranked data)

```
ZADD leaderboard 100 "alice" 200 "bob" 150 "carol"
ZRANGE leaderboard 0 -1
# alice carol bob (sorted by score)
ZRANK leaderboard "bob"
# 2
```

### Key expiry & sub-key TTLs

```
SET temp "data"
EXPIRE temp 30       # expires in 30 seconds
TTL temp             # 29
PERSIST temp         # remove the expiry
TTL temp             # -1 (no expiry)

# Per-field Hash TTLs, per-member Set TTLs, and per-member ZSet TTLs:
HEXPIRE user:1 60 FIELDS 1 session_token
SEXPIRE active_tokens 60 MEMBERS 1 tok_123
ZEXPIRE leaderboard 3600 MEMBERS 1 guest_player
```

### Native JSON, Time-Series, Search, Queues & Probabilistic Structures

Bonodis ships Redis Stack capabilities natively in the core binary (zero `.so` modules):

```
# Native JSON (JSON.*)
JSON.SET user:1 $ '{"name":"Ada","score":10}'
JSON.NUMINCRBY user:1 $.score 5
JSON.GET user:1 $.score

# Native Time-Series (TS.*)
TS.CREATE cpu:load RETENTION 60000 LABELS host web1
TS.ADD cpu:load * 42
TS.RANGE cpu:load - + AGGREGATION avg 10000

# Native Full-Text & Secondary Indexing (FT.*)
FT.CREATE idx:books ON HASH PREFIX 1 book: SCHEMA title TEXT genre TAG price NUMERIC SORTABLE
HSET book:1 title "Systems Programming in Mako" genre "tech,systems" price 45
FT.SEARCH idx:books "@genre:{tech} @price:[40 50]"

# Native Delayed & Retryable Job Queues (QUEUE.*)
QUEUE.PUSH q:jobs job1 '{"email":"ada@example.com"}' PRIORITY 10 MAXRETRIES 3
QUEUE.POP q:jobs worker1 VISIBILITY 30000
QUEUE.ACK q:jobs job1

# Probabilistic Suite (Bloom, Cuckoo, Count-Min Sketch, Top-K)
BF.ADD seen_urls "https://example.com"
CF.ADD deletable_filter "item1"
CMS.INITBYDIM freq_sketch 1000 5
TOPK.RESERVE hot_queries 10

# Atomic Compare-And-Swap, Fenced Locks & GCRA Rate Limiting
CAS config:version "v1" "v2" EX 60
LOCK ACQUIRE resource:db workerA 10000
CL.THROTTLE api:user:42 15 30 60 1
```

## Benchmark your instance

```
./bonodis-cli --bench -n 20000 -P 16 -c 4 -r 10000
```

Reports `req/s` along with `p50`, `p95`, and `p99` tail-latency percentiles across `PING`, `SET`, `GET`, `INCR`, `LPUSH`, `HSET`, `CAS`, `RATELIMIT`, `BF.ADD`, and `JSON.GET`.

## Add a password

```
./bonodis --bind 127.0.0.1 --port 6379 --requirepass mypassword
```

```
./bonodis-cli -a mypassword SET k v
# OK

./bonodis-cli SET k v
# NOAUTH Authentication required.
```

From Python:

```python
r = redis.Redis(host="127.0.0.1", port=6379, password="mypassword")
```

## Persist data

By default, Bonodis keeps everything in memory. Restart = data gone.

To persist:

```
./bonodis --bind 127.0.0.1 --port 6379 --appendonly yes --dir ./data --protected-mode no
```

Every write is appended to `./data/appendonly.aof`. On restart, the file is replayed and your data is back.

## Production checklist

```
./bonodis --prod --bind 0.0.0.0 --port 6379 \
    --requirepass <password> \
    --appendonly yes --dir /var/lib/bonodis \
    --maxmemory 1073741824 \
    --protected-mode yes
```

`--prod` enforces:
- `--maxmemory` must be set (prevents OOM kill)
- `--appendonly yes` must be set (prevents data loss on restart)
- Public bind requires `--requirepass`

## Next steps

- [Agent memory how-to](agent-memory.md) -- store and recall context for AI agents
- [REACT triggers how-to](react.md) -- server-side triggers that fire on writes
- [Cluster setup](cluster.md) -- run multiple nodes with automatic failover
