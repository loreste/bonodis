# Bonodis adversarial + whitehat report

Date: 2026-08-26  
Code: `/Users/loreste/bonodis`  
Version: **0.14.0**  
Method: live RESP attacks against `./bonodis`, plus independent **whitehat** (`audits/whitehat.md`) and **adversarial correctness** (`audits/adversarial.md`) source audits. This file is the living ship-status; the first-pass write-ups stay as historical evidence.

## Verdict

The store is a working Redis RESP2 speaker on Linux/macOS, MIT-licensed, 100% Mako. It is **not Redis**. With `--requirepass` and `--prod` (maxmemory + AOF) it is fit for a **private** network. Do **not** put an open bind on a public interface without a password, TLS, and `ulimit`/`maxclients` set.

Unauthenticated `SET`/`FLUSHALL` was **not** achieved when `requirepass` was set after the HELLO/MULTI/protected-mode patches.

## What 0.10.0 closed (this pass)

| Item | Status |
| --- | --- |
| Lua `EVAL` / `EVALSHA` / `SCRIPT LOAD` | **shipped** — sandboxed subset (`KEYS`/`ARGV`, `redis.call`/`pcall`, locals, assignment, `if`/`while`, `and`/`or`, `#`, `return`). No `os`/`io`/`load`/`require`. Same-slot keys. |
| Unix-domain listen | **shipped** (`--unixsocket`; CLI `-s`). File mode follows umask (`syscall_chmod` does not link). |
| Stream PEL | **shipped** — `XREADGROUP` `>` + pending re-read, `XACK`, Redis-shaped `XPENDING`, `XCLAIM`, `XAUTOCLAIM`, `XINFO CONSUMERS` |
| Replica/cluster TLS verify | **shipped** — `--tls-ca` / `tls_client_new(ca)`. Empty CA still uses the insecure client (self-signed). |
| `used_memory` for eviction | **shipped** — per-type payload recount on `MEMORY` and before LRU eviction (strings, hashes, lists, sets, zsets, streams + PEL, vectors) |
| Replica client writes | **shipped** — `-READONLY` |
| `maxclients` live `CONFIG SET` | **shipped** |

## Still not Redis (on purpose / infeasible in Mako)

- Redis modules (`.so` ABI)
- Redis-format RDB bytes (`dump.bonodis` + PSYNC command stream)
- Redis Cluster bus binary protocol (gossip is RESP `CLUSTERX`)
- Full Lua 5.1 VM (no first-class tables, no `os`/`io`, no `cjson`)
- Unix socket `chmod` (Mako does not export `_mako_syscall_chmod`)
- `SENTINEL` as a 3-process quorum (compatibility API on the data node only)

## Live attacks (first pass, still the baseline)

Two listeners: `--requirepass s3cret` on `:16381`, open on `:16382`.

- Unauth `GET`/`SET`/`INFO`/`CONFIG`/`FLUSHALL` → `NOAUTH`. Good.
- Unauth `PING` allowed. Fine.
- Parser: argc 4097 and `$33554433` → `-ERR protocol error`. Split frames OK.
- **SIGPIPE:** `PING`×50 then close unread → process gone (`exit 141`) **before** `signal_ignore("PIPE")`. After the patch, same probe leaves the process up.
- `HELLO AUTH` / unauth `MULTI` / unauth `COMMAND` were live-confirmed then patched.

## What 0.14.0 closed (this pass)

| Item | Status |
| --- | --- |
| SCAN no-args crash (SIGABRT) | **fixed** — arity check before `argv[1]` access in `merge_scan` |
| Nested MULTI silent clear | **fixed** — returns `-ERR MULTI calls can not be nested`, queue preserved |
| DISCARD without MULTI silent OK | **fixed** — returns `-ERR DISCARD without MULTI` |
| MULTI queue unbounded | **fixed** — capped at 10000 queued commands |
| SELECT non-integer → DB 0 | **fixed** — rejects with `int_ok`, no silent fallthrough |
| CONFIG SET unknown key → +OK | **fixed** — returns `-ERR Unsupported CONFIG parameter` |
| CONFIG unknown subcommand → +OK | **fixed** — returns `-ERR unknown CONFIG subcommand` |
| SRANDMEMBER negative count unbounded | **fixed** — capped at 10000 |
| EVAL numkeys int overflow | **fixed** — `nk > len(argv) - 3` avoids wrap (both dispatch and shard) |
| SETRANGE INT64_MAX offset crash | **fixed** — rejects offset > 512 MB |
| BITFIELD negative offset crash | **fixed** — rejects `off < 0` in GET/SET/INCRBY |
| EVAL 40k-paren stack overflow | **fixed** — pre-scan rejects nesting depth > 200 |
| Glob 100k-`?` stack overflow | **fixed** — iterative glob with single-star backtracking |
| MGET empty-string → nil | **fixed** — `resp_nil_mask` distinguishes `$-1` from `$0` |
| UNSUBSCRIBE doesn't exit sub-mode | **fixed** — unsub-all iterates channels; resets `subbed` on count 0 |
| XRANGE ignores start/end bounds | **fixed** — `xrange_cmp` filter (inline, avoids `xid_gte` shard crash) |
| Monolithic codebase | **fixed** — split `extra.mko` → geo/hll/bitops/stream; split `server.mko` → pubsub/replication/sentinel |

## Whitehat (security-auditor)

Full write-up: `audits/whitehat.md` (historical first pass). Caps, protected-mode host parse, AUTH-before-MULTI, `maxclients`/`maxmemory`, query-buffer limits, and SIGPIPE ignore closed the critical items. Remaining residual: thread-per-connection (mitigated by `maxclients` + accept-rate), `SCAN` still walks keys (iterates all, not cursor-based).

## Adversarial (correctness)

Full write-up: `audits/adversarial.md`. Highest items (AOF DB collapse, cross-shard `RENAME`, `KEEPTTL`, `MGET` WRONGTYPE, `MSETNX`, `ZADD nan`) were patched in-tree.

## Known open

- Multiple XADD to same key crashes (shard slice append aliasing)
- `SCAN` is still `KEYS`-and-slice, not true incremental cursor
- `wait_reply` busy-polls (condvar would be better)
- Thread-per-connection (mitigated by `maxclients` + `accept-rate`)

## Ship status (0.14.0)

Pub/sub, HyperLogLog, Sentinel compatibility API, `maxclients`/`maxmemory`, TLS (optional CA verify), ACL, MONITOR, stream groups with PEL/`XCLAIM`, replica `READONLY`, unix sockets, Lua EVAL subset, 4 accept threads, 50k default clients.

Still **not** Redis, on purpose: modules, Redis RDB bytes, Cluster bus binary. `EVAL` is a sandboxed subset, not Lua 5.1. Replica TLS without `--tls-ca` is still insecure (self-signed).
