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
makori --version
# should print makori 0.5.x or later
```

## Build Bonodis

```
git clone https://github.com/loreste/bonodis
cd bonodis
makori build --release -p lib -o bonodis
makori build --release -p cli -o bonodis-cli
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

### Key expiry

```
SET temp "data"
EXPIRE temp 30       # expires in 30 seconds
TTL temp             # 29
PERSIST temp         # remove the expiry
TTL temp             # -1 (no expiry)
```

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
