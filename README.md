# Bonodis

In-memory data store that speaks RESP2. Written in [Mako](https://github.com/loreste/mako). MIT licensed. Not a Redis fork.

Runs on Linux and macOS (x86_64, arm64). Windows is not supported (Unix syscalls). WSL2 works.

```
makori run -p lib -- --bind 127.0.0.1 --port 6379 --protected-mode no
makori run -p cli -- PING
makori run -p cli -- SET k v
makori run -p cli -- GET k
```

Version **0.14.0**. Needs [Mako](https://github.com/loreste/mako) 0.7.0+. See [install docs](docs/install.md).

## What it is

A RESP2-compatible key-value store with 16 shared-nothing shards, a WAL instead of fork-based persistence, and built-in commands for agent memory, knowledge graphs, and server-side triggers. Any Redis client library works out of the box.

## What it is not

Not Redis. Specifically:

- No Redis modules (`.so` ABI)
- No RDB file format (`dump.bonodis` is a command stream, not RDB bytes)
- No Redis Cluster bus binary protocol (gossip is RESP-based `CLUSTERX`)
- No full Lua 5.1 (`EVAL` is a sandboxed subset: `redis.call`, `redis.pcall`, `redis.status_reply`, `redis.error_reply`, `redis.sha1hex`, `KEYS`, `ARGV`, `string.*`, `math.*`, `cjson.encode`/`cjson.decode`, control flow; no `os`/`io`/`load`/`require`)
- No Sentinel quorum (compatibility API answers from the data node itself)
- ACL uses Bonodis `users.acl` format, not Redis ACL command-selector files
- `DUMP`/`RESTORE` payloads are `BND1`, not Redis RDB bytes

If your app depends on Redis modules, RDB snapshots, or full Lua 5.1 — Bonodis will not work.

## Architecture

```
clients --RESP2--> per-connection handlers
                       |
                       | crc16(hashtag(key)) % shards
                       v
            shard 0 .. shard 15
                       |
                       v
            reply board (CMap) --> client
                       |
                       v
            WAL persist task (optional)
```

One OS thread per connection. Commands on different keys run in parallel. A shard stays serial. Multi-key commands and multi-shard client pipelines scatter/gather concurrently across all involved shards. Expiry is lazy plus periodic background sweeps. 16 logical databases (`SELECT 0..15`).

Four `SO_REUSEPORT` accept threads (`--accept-threads`), 16k listen backlog, 50k default `--maxclients`. GET/SET skip the admin-command chain and go straight to the shard. `--prod` refuses to start without `--maxmemory` and `--appendonly yes`.

## Run

```
makori run -p lib -- --port 6379 --bind 0.0.0.0 --shards 16 \
    --dir ./data --appendonly yes --requirepass secret --protected-mode yes \
    --maxclients 50000 --maxmemory 268435456 \
    --metrics-port 9090 --appendfsync everysec
```

Production mode:

```
bonodis --prod --bind 0.0.0.0 --port 6379 --dir /var/lib/bonodis \
    --appendonly yes --appendfsync everysec --maxmemory 268435456 \
    --requirepass secret --protected-mode yes
```

### Flags

| Flag | Default | Notes |
| --- | --- | --- |
| `--port` | `6379` | Listen port |
| `--bind` | `0.0.0.0` | Bind address |
| `--shards` | `16` | Shard workers (max 16) |
| `--dir` | `.` | Data directory for the WAL and snapshots |
| `--appendonly` | `no` | `yes` to persist writes |
| `--appendfsync` | `everysec` | `always` (fsync each write), `everysec`, `no` (never) |
| `--requirepass` | empty | `AUTH` password |
| `--protected-mode` | `yes` | Reject non-loopback clients when no password is set |
| `--maxclients` | `50000` | Connection cap |
| `--maxmemory` | `0` | Byte budget; `0` = unlimited. `allkeys-lru` eviction per shard |
| `--default-ttl` | `0` | Seconds; applied to `SET`/`MSET`/`APPEND`/`INCR` when no `EX`/`PX` given. `0` = off |
| `--log-level` | `info` | `debug` / `info` / `warn` / `error` |
| `--log-json` | `no` | JSON lines when `yes` |
| `--logfile` | stderr | Append logs to this path |
| `--log-commands` | `no` | Log every command at info level |
| `--accept-threads` | `4` | `SO_REUSEPORT` accept loops (1–4) |
| `--accept-rate` | `50000` | New TCP accepts per thread per second |
| `--slowlog-slower-than` | `10000` | Microseconds; `0` logs all |
| `--metrics-port` | `0` | Prometheus HTTP `/metrics` port (disabled when `0`) |
| `--cluster-enabled` | `no` | Redis Cluster mode |
| `--cluster-announce-ip` | bind / `127.0.0.1` | Address other nodes use to reach this one |
| `--replica-of` | empty | `HOST:PORT` of master |
| `--auto-failover` | `yes` in cluster | Replica watchdog with majority vote |
| `--prod` | off | Require `--maxmemory` + `--appendonly yes`; public bind requires `--requirepass` |
| `--timeout` | `0` | Idle client timeout (seconds) |
| `--tcp-keepalive` | `0` | TCP keepalive idle (seconds) |
| `--tls-cert` / `--tls-key` | empty | PEM paths for TLS |
| `--tls-ca` | empty | CA PEM for verified peer TLS |
| `--aclfile` | empty | Load `users.acl` at startup |
| `--unixsocket` | empty | Unix-domain socket path (in addition to TCP) |
| `--unixsocketperm` | `700` | Reported in `CONFIG GET`; actual mode follows umask |

### CLI

```
bonodis-cli -h 127.0.0.1 -p 6379 PING
bonodis-cli -h 127.0.0.1 -p 6379 -i                  # Interactive REPL
bonodis-cli -a secret SET k v
bonodis-cli --tls PING
bonodis-cli --tls-ca /path/ca.pem PING
bonodis-cli -s /tmp/bonodis.sock PING
bonodis-cli -u alice -a secret ACL WHOAMI
bonodis-cli --bench -n 50000 -P 16 -c 4 -r 10000     # Multi-client, multi-shard benchmark with p50/p95/p99
```

### Client libraries

Bonodis speaks RESP2. Use any Redis client: Python `redis`, Node `ioredis`/`redis`, Go `go-redis`, Rust `redis-rs`, Java `jedis`, Ruby `redis`, Lua `redis-lua`/OpenResty `resty.redis`.

```python
import redis
r = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)
r.set("k", "v")
r.get("k")
```

## Commands

### Connection / server

`PING`, `ECHO`, `QUIT`, `AUTH` (password or user + password), `SELECT`, `HELLO`, `COMMAND LIST`/`COUNT`/`DOCS`/`GETKEYS`, `TIME`, `CLIENT ID`/`SETNAME`/`GETNAME`/`LIST`/`INFO`/`KILL`/`TRACKING` (`ON`/`OFF`/`BCAST`/`PREFIX` with `__redis__:invalidate` notifications)/`TRACKINGINFO`, `CONFIG GET`/`SET`/`REWRITE`/`RESETSTAT`, `INFO`, `SLOWLOG`, `METRICS`, `MEMORY`/`MEMORY USAGE`, `LASTSAVE`, `SAVE`/`BGSAVE`, `BGREWRITEAOF`, `SHUTDOWN [SAVE|NOSAVE]`, `ACL SETUSER`/`LIST`/`GETUSER`/`WHOAMI`/`SAVE`/`LOAD`, `OBJECT ENCODING`/`IDLETIME`, `LATENCY`, `PUBSUB`, `MONITOR`

### Strings

`GET`, `SET` (`NX`/`XX`/`GET`/`EX`/`PX`/`EXAT`/`PXAT`/`KEEPTTL`), `SETNX`, `SETEX`, `PSETEX`, `GETSET`, `GETDEL`, `GETEX`, `GETRANGE`, `SUBSTR`, `SETRANGE`, `LCS` (`LEN`/`IDX`/`MINMATCHLEN`/`WITHMATCHLEN`), `CAS` (atomic Compare-And-Swap with `EX`/`PX`/`EXAT`/`PXAT`/`KEEPTTL`), `CAD` (atomic Compare-And-Delete), `DELEX` (`IFEQ`/`IFNE`), `RATELIMIT` (atomic window rate limiter), `CL.THROTTLE` (native `redis-cell` GCRA rate limiter), `LOCK` (`ACQUIRE`/`RENEW`/`RELEASE`/`INFO` fenced distributed locks with monotonic fencing tokens), `APPEND`, `STRLEN`, `INCR`, `INCRBY`, `INCRBYFLOAT`, `DECR`, `DECRBY`, `MGET`, `MSET`, `MSETNX`, `COPY`, `TOUCH`, `DUMP`/`RESTORE`

### Keys

`DEL`, `UNLINK`, `EXISTS`, `TYPE`, `EXPIRE` (`NX`/`XX`/`GT`/`LT`), `PEXPIRE`, `EXPIREAT`, `PEXPIREAT`, `EXPIRETIME`, `PEXPIRETIME`, `TTL`, `PTTL`, `PERSIST`, `RENAME`, `RENAMENX`, `MOVE`, `SWAPDB`, `KEYS` (capped at 4096), `SCAN` (`MATCH`/`COUNT`/`TYPE`), `HOTKEYS`, `RANDOMKEY`, `DBSIZE`, `FLUSHDB`, `FLUSHALL`

### Hashes

`HSET`, `HMSET`, `HSETNX`, `HSETEX` (`FNX`/`FXX`/`EX`/`PX`/`EXAT`/`PXAT`/`KEEPTTL`), `HGET`, `HMGET`, `HGETEX` (`EX`/`PX`/`EXAT`/`PXAT`/`PERSIST`), `HGETALL`, `HDEL`, `HGETDEL`, `HEXISTS`, `HKEYS`, `HVALS`, `HLEN`, `HINCRBY`, `HINCRBYFLOAT`, `HSTRLEN`, `HRANDFIELD [COUNT [WITHVALUES]]`, `HSCAN` (`MATCH`/`COUNT`), `HEXPIRE`/`HPEXPIRE`/`HEXPIREAT`/`HPEXPIREAT` (`NX`/`XX`/`GT`/`LT`), `HEXPIRETIME`, `HPEXPIRETIME`, `HTTL`, `HPTTL`, `HPERSIST`

### Lists (True $O(1)$ Head-Slack Deque)

`LPUSH`, `RPUSH`, `LPUSHX`, `RPUSHX`, `LPOP`, `RPOP`, `LMPOP`, `BLPOP`, `BRPOP`, `BLMPOP`, `BLMOVE`, `BRPOPLPUSH`, `LRANGE`, `LLEN`, `LINDEX`, `LPOS`, `LSET`, `LTRIM`, `LREM`, `LINSERT`, `LMOVE`, `RPOPLPUSH`

### Sets

`SADD`, `SREM`, `SISMEMBER`, `SMISMEMBER`, `SMEMBERS`, `SCARD`, `SPOP`, `SRANDMEMBER`, `SMOVE`, `SUNION`, `SINTER`, `SDIFF`, `SINTERCARD`, `SUNIONSTORE`, `SINTERSTORE`, `SDIFFSTORE`, `SSCAN`, `SEXPIRE`/`SPEXPIRE`/`SEXPIREAT`/`SPEXPIREAT` (`NX`/`XX`/`GT`/`LT` per-member TTLs), `STTL`, `SPTTL`, `SPERSIST`

### Sorted sets

`ZADD` (`NX`/`XX`/`GT`/`LT`/`CH`/`INCR`), `ZREM`, `ZSCORE`, `ZMSCORE`, `ZCARD`, `ZRANGE` (`BYSCORE`/`BYLEX`/`REV`/`LIMIT`/`WITHSCORES`), `ZRANGESTORE`, `ZREVRANGE`, `ZRANGEBYSCORE`, `ZREVRANGEBYSCORE`, `ZRANGEBYLEX`, `ZREVRANGEBYLEX`, `ZCOUNT`, `ZLEXCOUNT`, `ZPOPMIN`, `ZPOPMAX`, `ZMPOP`, `BZPOPMIN`, `BZPOPMAX`, `BZMPOP`, `ZRANK [WITHSCORE]`, `ZREVRANK [WITHSCORE]`, `ZINCRBY`, `ZRANDMEMBER`, `ZUNION`/`ZINTER`/`ZDIFF`, `ZINTERCARD`, `ZUNIONSTORE`/`ZINTERSTORE`/`ZDIFFSTORE`, `ZREMRANGEBYSCORE`, `ZREMRANGEBYRANK`, `ZREMRANGEBYLEX`, `ZSCAN`, `ZEXPIRE`/`ZPEXPIRE`/`ZEXPIREAT`/`ZPEXPIREAT` (`NX`/`XX`/`GT`/`LT` per-member TTLs), `ZTTL`, `ZPTTL`, `ZPERSIST`

### Sort / Probabilistic / JSON / Time-Series / Search / Job Queues

- **Sort & HyperLogLog**: `SORT` (`ALPHA`/`DESC`/`LIMIT`/`STORE`), `SORT_RO`, `PFADD`, `PFCOUNT`, `PFMERGE`
- **Native Bloom Filters**: `BF.RESERVE`, `BF.ADD`, `BF.MADD`, `BF.EXISTS`, `BF.MEXISTS`, `BF.CARD`, `BF.INFO`
- **Native Cuckoo Filters (deletable probabilistic sets)**: `CF.RESERVE`, `CF.ADD`, `CF.ADDNX`, `CF.INSERT`, `CF.INSERTNX`, `CF.EXISTS`, `CF.MEXISTS`, `CF.DEL`, `CF.COUNT`, `CF.INFO`
- **Native Count-Min Sketch**: `CMS.INITBYDIM`, `CMS.INITBYPROB`, `CMS.INCRBY`, `CMS.QUERY`, `CMS.INFO`
- **Native Top-K Heavy Hitters**: `TOPK.RESERVE`, `TOPK.ADD`, `TOPK.INCRBY`, `TOPK.QUERY`, `TOPK.COUNT`, `TOPK.LIST [WITHCOUNT]`, `TOPK.INFO`
- **Native JSON (RedisJSON drop-in)**: `JSON.SET` (`NX`/`XX`), `JSON.GET`, `JSON.MGET`, `JSON.DEL`, `JSON.FORGET`, `JSON.TYPE`, `JSON.NUMINCRBY`, `JSON.STRAPPEND`, `JSON.STRLEN`, `JSON.ARRAPPEND`, `JSON.ARRLEN`, `JSON.OBJKEYS`, `JSON.OBJLEN`
- **Native Time-Series (RedisTimeSeries drop-in)**: `TS.CREATE` (`RETENTION`/`LABELS`), `TS.ADD`, `TS.MADD`, `TS.INCRBY`, `TS.DECRBY`, `TS.GET`, `TS.RANGE` / `TS.REVRANGE` (`COUNT` + `AGGREGATION avg|sum|min|max|count|first|last bucket_ms`), `TS.INFO`
- **Native Full-Text & Secondary Indexing (RediSearch drop-in)**: `FT.CREATE idx [ON HASH|JSON] [PREFIX n p1 ...] SCHEMA field TEXT|TAG|NUMERIC [SORTABLE] ...`, `FT.SEARCH idx query [NOCONTENT] [LIMIT offset num] [SORTBY field [ASC|DESC]] [RETURN n f1 ...]`, `FT.INFO`, `FT.DROPINDEX [DD]`, `FT._LIST`
- **Native Delayed & Retryable Job Queues**: `QUEUE.PUSH key job_id payload [DELAY ms] [PRIORITY pri] [MAXRETRIES n]`, `QUEUE.POP key worker_id [VISIBILITY ms] [COUNT n]`, `QUEUE.ACK key job_id ...`, `QUEUE.NACK key job_id [DELAY ms]`, `QUEUE.DLQ key [LIST|RETRY job_id|PURGE]`, `QUEUE.STATS key`

### Bitmaps

`SETBIT`, `GETBIT`, `BITCOUNT`, `BITPOS`, `BITOP` (`AND`/`OR`/`XOR`/`NOT`), `BITFIELD` (`GET`/`SET`/`INCRBY` `uN`)

### Geo

`GEOADD`, `GEODIST`, `GEOPOS`, `GEORADIUS`, `GEOSEARCH`, `GEOSEARCHSTORE`

### Streams

`XADD`, `XLEN`, `XRANGE`, `XREVRANGE`, `XREAD`, `XDEL`, `XTRIM`, `XGROUP CREATE`/`DESTROY`/`SETID`, `XREADGROUP` (`>` new + pending re-read + `NOACK`), `XACK`, `XPENDING` (summary + range), `XCLAIM`, `XAUTOCLAIM`, `XINFO STREAM`/`GROUPS`/`CONSUMERS`

### Transactions

`MULTI`, `EXEC`, `DISCARD`, `WATCH`/`UNWATCH` (watched keys abort `EXEC` with a null array if they changed)

### Pub/sub

`PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, `PSUBSCRIBE` (glob), `PUNSUBSCRIBE`

### Lua

`EVAL`, `EVALSHA`, `EVAL_RO`, `EVALSHA_RO`, `SCRIPT LOAD`/`EXISTS`/`FLUSH`/`KILL`

Sandboxed subset. Available: `KEYS`, `ARGV`, `redis.call`, `redis.pcall`, `redis.status_reply`, `redis.error_reply`, `redis.sha1hex`, `string.len`, `string.sub`, `string.lower`, `string.upper`, `string.find`, `string.rep`, `math.min`, `math.max`, `math.abs`, `math.floor`, `cjson.encode`, `cjson.decode` (with `.field` and `["field"]` access), `tonumber`, `tostring`, local variables, assignment, `if`/`while`, `and`/`or`, `#`, `..`, `return`, string literals, numbers. `EVAL_RO`/`EVALSHA_RO` strictly reject write commands inside `redis.call`/`redis.pcall`. Not available: `os`, `io`, `load`, `require`, metatables. Nesting depth capped at 200. Script size capped at 64KB.

### Cluster / replication

`CLUSTER KEYSLOT`/`MYID`/`INFO`/`SLOTS`/`NODES`/`MEET`/`ADDSLOTS`/`ADDSLOTSRANGE`/`REPLICATE`/`FAILOVER`/`FORGET`/`REPLICAS`/`SAVECONFIG`, `ROLE`, `REPLICAOF`/`SLAVEOF`, `REPLCONF`, `PSYNC`/`SYNC`, `WAIT`, `READONLY`/`READWRITE`, `SENTINEL MASTERS`/`MASTER`/`GET-MASTER-ADDR-BY-NAME`/`SLAVES`/`CKQUORUM`

## Vectors

`VADD key id float [float ...] [QUANTIZED|INT8] [ATTR text]` stores a float vector (or 8x smaller `int8` scalar-quantized vector when `QUANTIZED` is passed). `VSIM key COUNT n WITHSCORES float [float ...]` ranks by cosine similarity. `VSEARCH key [COUNT n] [FILTER substr] [TEXT query] [MINSCORE sc] [WITHSCORES] [WITHATTR] [VALUES f1 f2 ...]` runs hybrid vector cosine + token-overlap + attribute filter search in one call. `VREM`, `VCARD`, `VDIM`, `VATTR`, `VGETATTR`.

Embeddings are computed by the client. Bonodis stores and ranks. It does not call a model.

## BRAIN (agent memory)

Server-side commands for storing, recalling, and packing agent context. All keys that need to work together must share a hash tag (`{agent}sess`, `{agent}mem`).

| Command | What it does |
| --- | --- |
| `BRAIN REMEMBER ns id text [floats...]` | Store text on a vector key. Floats optional. |
| `BRAIN RECALL ns COUNT n [QUERY text] [floats...]` | Rank by cosine (if floats given) or token overlap. |
| `BRAIN SAY session role content` | `RPUSH` of `role<tab>content` to the session list. |
| `BRAIN CONTEXT session` | `LRANGE` of the session list. |
| `BRAIN PACK session ns [QUERY text]` | Concatenate recall hits + last 20 conversation entries + related edges/facts. Empty sections omitted. |
| `BRAIN COMPACT ns` | Merge memory texts whose token overlap is >= 0.6. |
| `BRAIN CACHE SET hash response` / `GET hash` | `HSET`/`HGET` on `brain:cache`. |
| `BRAIN HELP` | List available subcommands. |

```
bonodis-cli BRAIN REMEMBER "{a}mem" p1 "user prefers dark mode"
bonodis-cli BRAIN SAY "{a}sess" user "make it darker"
bonodis-cli BRAIN PACK "{a}sess" "{a}mem" QUERY darker
```

## Graph, facts, leases

Edges, subject-predicate-object triples, and single-holder leases. Same-slot keys only (use `{tag}`).

| Command | What it does |
| --- | --- |
| `RELATE a b label` | Create a directed edge. |
| `UNRELATE a b` | Remove edges between a and b. |
| `NEIGHBORS key` | List adjacent keys. |
| `PATH a b` | Shortest path (BFS, cap 6 hops). |
| `FACT ADD key predicate object` | Store a triple. |
| `FACT DEL key predicate object` | Remove a triple. |
| `FACT OF key` | List all triples on a key. |
| `FACT WHO key predicate` | Objects for a predicate. |
| `BELIEVE key pred obj [0-100]` | `FACT ADD` plus an integer confidence score. |
| `TENSIONS key` | Predicates with two or more objects (contradictions). |
| `ASK key OF` / `WHO pred` / `QUERY text` / `HOPS n` | Query facts, edges, or BFS. |
| `ATTEND session key` | Prepend key to a 24-item focus list on session. |
| `FOCUS session` | Return the focus list. |
| `BUDGET key amount` | Set a non-negative integer counter. |
| `SPEND key amount` | Decrement counter; errors if it would go below zero. |
| `LEASE key seconds` | Single-holder lease. |
| `LEASED key` | Check if leased. |
| `UNLEASE key` | Release. |
| `WHY key` | Show edges, facts, and confidence for a key. |

```
bonodis-cli RELATE "{b}sess" "{b}pref" "about"
bonodis-cli FACT ADD "{b}sess" likes "dark mode"
bonodis-cli BELIEVE "{b}sess" prefers "vim" 80
bonodis-cli TENSIONS "{b}sess"
```

## TURN

`TURN session ns [QUERY text]` is a read. It prints session and ns, then budget (if set), focus (if non-empty), tensions (if any), and the same text `BRAIN PACK` would produce. Empty sections are omitted. Session and ns must share a slot. `BRAIN TURN` is an alias.

```
bonodis-cli TURN "{d}sess" "{d}mem" QUERY darker
curl -s http://127.0.0.1:9090/turn -d '{"session":"{d}sess","ns":"{d}mem","query":"darker"}'
```

## REACT (server-side triggers)

`REACT CREATE name key_or_glob ON WRITE|DELETE|EXPIRE|ANY cmd [arg ...] [| cmd [arg ...]]`

Registers a trigger. When `key_or_glob` (exact key or glob pattern such as `user:*`) is written, deleted, or expired, the listed commands run on the same shard, same thread, no network round-trips. Pipe `|` chains commands. `$RESULT` from the previous command feeds into the next.

```
# Copy a value on write
REACT CREATE copier {r}src ON WRITE SET {r}dst $VALUE
SET {r}src hello
GET {r}dst    # "hello"

# Glob + ON EXPIRE trigger
REACT CREATE audit sess:* ON EXPIRE INCR stats:expired

# Chain commands
REACT CREATE chain {c}src ON WRITE GET {c}src | SET {c}copy $RESULT
SET {c}src foo
GET {c}copy   # "foo"

# Automatic context rebuild on memory write
REACT CREATE rebuild {a}mem ON WRITE BRAIN COMPACT {a}mem | BRAIN PACK {a}sess {a}mem
BRAIN REMEMBER {a}mem p1 "user prefers dark mode"
# compact + pack ran server-side; context is fresh
```

Substitutions: `$KEY` (triggered key), `$VALUE` (`argv[2]` of the write command), `$RESULT` (RESP payload of previous piped command).

Constraints:
- Trigger and target keys must share a hash tag (same shard)
- Exact keys and glob patterns (`*`, `?`, `[...]`) are supported
- Rules persist in the WAL, survive restarts
- No recursive triggers (a trigger's writes do not fire other triggers)
- `REACT DELETE name` removes a rule
- `REACT LIST` returns all rules as name/key pairs

## HTTP API

Enabled when `--metrics-port` is set. Loopback only.

| Method | Path | Body | Notes |
| --- | --- | --- | --- |
| GET | `/api` | | Discovery |
| GET | `/api/ping` | | |
| POST | `/api` | `{"argv":["SET","k","v"]}` | Run any command |
| POST | `/api/pipeline` | `{"commands":[["GET","k"],["SET","k","v"]]}` | Pipeline |
| GET | `/health` | | |
| GET | `/metrics` | | Prometheus text format |
| GET | `/play` | | HTML form that posts to `/api` |
| POST | `/mcp` | `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` | JSON-RPC 2.0 |
| POST | `/brain/remember` | `{"ns":"mem","id":"p1","text":"...","vector":[0.1,0.2]}` | |
| POST | `/brain/recall` | `{"ns":"mem","query":"theme","k":5,"vector":[0.1,0.2]}` | |
| POST | `/brain/say` | `{"session":"chat","role":"user","content":"..."}` | |
| GET | `/brain/context?session=chat` | | |
| POST | `/brain/pack` | `{"session":"chat","ns":"mem","query":"...","k":8}` | |
| POST | `/brain/cache` | `{"hash":"abc","response":"..."}` | |
| GET | `/brain/cache?hash=abc` | | |
| GET | `/brain/help` | | |
| POST | `/turn` | `{"session":"{d}sess","ns":"{d}mem","query":"darker"}` | |

Password: JSON `"auth"` field, or `X-Bonodis-Auth` header, or `Authorization: Bearer ...`.

Reply shape: `{"ok":true,"result":...}` or `{"ok":false,"error":"..."}`.

MCP endpoint (`/mcp`) supports JSON-RPC 2.0 methods: `initialize`, `tools/list`, `tools/call`, `ping`. HTTP POST only (not Streamable HTTP, SSE, or stdio).

## Cluster

Three masters:

```
bonodis --port 7000 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b0
bonodis --port 7001 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b1
bonodis --port 7002 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b2
bonodis-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002
```

Add a replica:

```
bonodis --port 7003 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b3
bonodis-cli --cluster add-node 127.0.0.1:7003 127.0.0.1:7000 --slave
```

Six nodes, one replica per master:

```
bonodis-cli --cluster create --replicas 1 \
    127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 \
    127.0.0.1:7003 127.0.0.1:7004 127.0.0.1:7005
```

Wrong-node keys return `-MOVED <slot> ip:port`. Topology stored in `<dir>/nodes.conf`. Slot hashing: `crc16(hashtag(key)) & 16383`. Keys with the same `{tag}` land on the same shard.

Auto-failover (cluster, default on): after ~3s of failed master pings, the replica with the lowest node id collects votes from the other replicas. Promotion needs `n_replicas/2+1` votes. Manual `CLUSTER FAILOVER` force-promotes without a vote. Two replicas require both votes (one failure blocks failover). Use three replicas to survive one loss.

## Replication

```
bonodis --port 6380 --bind 127.0.0.1 --protected-mode no --replica-of 127.0.0.1:6379
```

`PSYNC` full resync is a stream of write commands, not an RDB dump. `REPLICAOF NO ONE` promotes back to master. Replicas refuse client writes (`-READONLY`).

`SENTINEL GET-MASTER-ADDR-BY-NAME` / `MASTERS` / `CKQUORUM` answer from the data process. There is no separate Sentinel process. Clients that expect sentinel:// can connect.

## Persistence

`--appendonly yes` enables the WAL. Each write is appended as `db\nRESP`. `--appendfsync` controls when the file is fsynced.

`SAVE` writes `<dir>/dump.bonodis` (a command stream, not RDB). No fork. `BGREWRITEAOF` rebuilds `appendonly.aof` from the live store to prevent unbounded WAL growth.

## Logging

Structured slog (text or `--log-json yes`). Default level `info`.

| Level | What it covers |
| --- | --- |
| `error` | Listen/AOF/cluster-meet failures |
| `warn` | AUTH fail, NOAUTH, protocol errors, maxclients, CROSSSLOT, CLUSTERDOWN, slow commands, replica disconnect |
| `info` | Startup, config, AUTH ok, AOF, cluster operations, replica PSYNC, eviction |
| `debug` | Client connect/close, every command + reply, `MOVED`, replica apply, gossip, `nodes.conf` writes |

`--log-commands yes` promotes each command to info. AUTH passwords are never logged.

## Limits

| Limit | Value |
| --- | --- |
| Unauthenticated query buffer | 64 KiB |
| Authenticated query buffer | 16 MiB |
| Max bulk string | 4 MiB |
| Max RESP array elements | 4096 |
| Max `KEYS` matches | 4096 (use `SCAN`) |
| Lua nesting depth | 200 |
| Lua script size | 64 KB |
| MULTI queue depth | 10000 |
| SRANDMEMBER negative count | capped at 10000 |
| SETRANGE offset | capped at 512 MB |

Protected-mode checks parse the peer address as an IP (`127.0.0.0/8`, `::1`, `::ffff:127.0.0.0/8`). In cluster mode, cross-slot `RENAME`, `COPY`, and `MSETNX` return `CROSSSLOT` (in standalone multi-shard mode, `RENAME`, `RENAMENX`, and `COPY` work transparently across shards for all data types and TTLs). Replicas refuse writes. `ZADD` rejects `nan`/`inf`. `CONFIG SET` of unknown keys returns an error. Raise `ulimit -n` above `--maxclients`.

## Deploy

```
# systemd
sudo cp bonodis /usr/local/bin/bonodis
sudo cp deploy/bonodis.service /etc/systemd/system/
sudo useradd -r -s /usr/sbin/nologin bonodis
sudo mkdir -p /var/lib/bonodis && sudo chown bonodis:bonodis /var/lib/bonodis
sudo systemctl enable --now bonodis

# Docker
makori build --release -p lib -o bonodis
docker build -t bonodis .
docker run --name bonodis -p 6379:6379 -v bonodis-data:/data bonodis

# TLS
bonodis --tls-cert cert.pem --tls-key key.pem --bind 127.0.0.1 --protected-mode no
bonodis-cli --tls PING

# Unix socket
bonodis --bind 127.0.0.1 --unixsocket /tmp/bonodis.sock --protected-mode no
bonodis-cli -s /tmp/bonodis.sock PING

# Bench (needs a running server)
./scripts/bench.sh 127.0.0.1 6379 20000
makori bench -p lib
```

## Tests

```
makori test .
```

Unit tests (store, RESP codec, CRC16, glob, Lua) and live TCP tests (every command group, cluster, replication, TLS, unix sockets, pub/sub, streams, ACL, adversarial probes). All tests are in-process.

## Documentation

- [Install](docs/install.md) -- requirements, platforms, systemd, Docker
- [Getting started](docs/getting-started.md) -- first commands, language examples, JSON/TS/Search/Queues, production checklist
- [Agent memory](docs/agent-memory.md) -- store/recall/pack context, quantized `int8` vectors, and hybrid `VSEARCH`
- [REACT triggers](docs/react.md) -- server-side triggers on `WRITE`, `DELETE`, `EXPIRE`, and `ANY` with glob patterns
- [Graph, facts, leases](docs/graph-and-facts.md) -- edges, triples, beliefs, budgets, fenced `LOCK`, `QUEUE.*`, and `FT.*`
- [Cluster setup](docs/cluster.md) -- multi-node with failover
- [HTTP API](docs/http-api.md) -- JSON API, Brain endpoints, MCP
- [Lua scripting](docs/lua-eval.md) -- `EVAL` / `EVAL_RO` sandbox with `string.*`, `math.*`, `cjson.*`, and `redis.*`
- [Persistence](docs/persistence.md) -- WAL, snapshots, fsync
- [TLS](docs/tls.md) -- encrypted connections
- [ACL](docs/acl.md) -- per-user access control

## Layout

```
lib/
  server.mko      connection handling, parallel multi-shard pipeline scatter-gather, config, accept loops
  store.mko       core data types (string, hash, O(1) head-slack deque list, set, zset), shard loop
  extra.mko       sort, scan, dump/restore, sub-key TTLs, CAS/CAD/DELEX, RATELIMIT/CL.THROTTLE, JSON.*, TS.*
  stream.mko      XADD/XRANGE/XREADGROUP/PEL and stream helpers
  bitops.mko      SETBIT/GETBIT/BITCOUNT/BITOP/BITFIELD
  geo.mko         GEOADD/GEODIST/GEOPOS/GEORADIUS/GEOSEARCH
  hll.mko         PFADD/PFCOUNT/PFMERGE, BF.* (Bloom), CF.* (Cuckoo), CMS.* (Count-Min), TOPK.* (Top-K)
  brain.mko       BRAIN commands, quantized VADD/VSIM/VSEARCH, HTTP /brain/* API
  mind.mko        BELIEVE/TENSIONS/ASK/ATTEND/BUDGET/SPEND/TURN
  graph.mko       RELATE/UNRELATE/NEIGHBORS/PATH/FACT/WHY, LOCK, QUEUE.*, FT.* (RediSearch drop-in)
  react.mko       REACT CREATE/DELETE/LIST, WRITE/DELETE/EXPIRE/ANY + glob trigger execution
  cluster.mko     CLUSTER commands, slot routing, gossip, failover
  replication.mko replica worker, PSYNC feed, master ingest
  pubsub.mko      SUBSCRIBE/PUBLISH, MONITOR
  sentinel.mko    SENTINEL compatibility API
  lua.mko         EVAL / EVAL_RO sandbox + string.*, math.*, cjson.*, redis.* stdlib
  resp.mko        zero-copy RESP2 codec, command names
  acl.mko         ACL
  api.mko         HTTP JSON /api, /mcp
  persist.mko     WAL read/write
  log.mko         structured logging
  netio.mko       TLS/TCP helpers
  consts.mko      buffer limits
  client.mko      RESP2 test client
  *_test.mko      unit + live TCP tests
cli/              CLI (single-shot, -i REPL, --cluster, --bench with -c/-r and p50/p95/p99 histograms)
clients/          Lua / Python / JS HTTP helpers
deploy/           systemd unit
scripts/          bench.sh
Dockerfile        release binary
```

## Known limitations

- Thread per connection (mitigated by `maxclients` + `accept-rate`, zero-copy cursor RESP parsing, and pipelined write coalescing, though no epoll/io_uring event loop)
- `SCAN` / `HSCAN` / `SSCAN` / `ZSCAN` sort matching keys/elements per call for deterministic cursor pagination rather than maintaining stateful cursor iterators
- `wait_reply` busy-polls at 50us intervals (should be a condvar)
- Cross-shard `RENAME` / `COPY` in standalone mode is staged (`DUMP` -> `RESTORE` -> `DEL`) rather than globally locked across shards
- `WATCH`/`MULTI`/`EXEC` is per-shard, not cross-shard atomic
- No Windows, no BSD

## License

MIT. Redis is a trademark of Redis Ltd. Bonodis is not affiliated with Redis Ltd.
