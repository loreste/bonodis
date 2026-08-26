# Security Audit: Bonodis (Redis-protocol store)

Scope: `lib/server.mko`, `lib/resp.mko`, `lib/store.mko`, `lib/persist.mko`, `lib/crc16.mko`, `lib/glob.mko`, `lib/main.mko`, `README.md`.

Threat model: unauthenticated TCP client to `:6379`; authenticated client escaping AUTH/ACL, crashing the process, exhausting CPU/memory, or poisoning WAL; local attacker supplying flags or a malicious AOF.

## Summary

**Overall risk: critical.** Bonodis is a network-facing Redis drop-in that binds `0.0.0.0:6379` by default. Several pre-auth paths allocate attacker-controlled amounts of memory and threads, so a remote client that has not presented `requirepass` can OOM or fd-exhaust the process. Protected-mode — the only remote barrier when no password is set — uses substring matching that treats many IPv6 peers as loopback. `MULTI`/`EXEC` skip the AUTH gate entirely (queueing is unauthenticated and unbounded). `SCAN` is implemented as cluster-wide `KEYS` plus recursive glob matching, so the “safe” cursor API is a CPU/stack DoS. Cross-shard `MSETNX`/`RENAME` are check-then-act races, and AOF replay always applies to DB 0, collapsing logical DB isolation on restart.

Classic Redis pre-auth RCE gadgets (`EVAL`, `SLAVEOF`, `DEBUG`, `MODULE`) are absent. AUTH is checked for ordinary data commands *after* parse. Those are real positives; they do not offset the parser/DoS and protected-mode issues on an open port.

| Severity        | Count |
|-----------------|-------|
| critical        | 2     |
| high            | 8     |
| medium          | 8     |
| low             | 4     |
| informational   | 3     |

---

### Finding 1: Unauthenticated unbounded parse buffer and 4096 × 32MiB bulk allocation
- **Severity**: critical
- **Category**: A04:2021 Insecure Design / Resource Exhaustion (pre-auth)
- **Location**: `lib/server.mko:671-686`, `lib/resp.mko:162-224` (caps at `lib/resp.mko:179-181` and `lib/resp.mko:208-210`)
- **Description**: `handle_conn` appends every `tcp_read` chunk to `buf` with no ceiling, then calls `parse_cmd` *before* `handle_one`’s AUTH check. Inline telnet form waits for CRLF with no length limit. RESP arrays allow `argc <= 4096` and each bulk `blen <= 33554432` (32MiB inclusive). The caps are independent: one command can materialize `4096 * 32MiB ≈ 128GiB` of argument strings. Negative bulk lengths other than a true null are accepted as empty strings (`lib/resp.mko:203-207`), so the 32MiB check is skipped for any `blen < 0`.
- **Impact**: A remote client that has not authenticated can OOM-kill the process. This works even with `--requirepass` set, because protected-mode is disabled when a password exists (`lib/server.mko:653`) and the listener still `detach`es a handler that parses first. Incomplete `*1\r\n$33554432\r\n` + slow drip holds ~32MiB per connection; thousands of connections multiply that.
- **Reproduction**:
  1. Start `./bonodis --bind 0.0.0.0 --port 6379 --requirepass secret` (or no password).
  2. From a remote host, TCP-connect and send (no `AUTH`):
     ```
     AAAA…  (no CRLF, keep sending)
     ```
     Process RSS grows without bound.
  3. Or send a well-formed header `*4096\r\n` followed by 4096 copies of `$33554432\r\n` + 32MiB payload + `\r\n`. Parser allocates ~128GiB before `NOAUTH` is ever considered.
  4. Confirm AUTH is not involved: `parse_cmd` returns only after the full array is in `argv`; `handle_one` runs later (`lib/server.mko:737`).
- **Remediation**:
  - Reject the connection if `len(buf)` exceeds a small cap (Redis-style `client-query-buffer-limit`, e.g. 1GiB *and* a much smaller unauthenticated cap).
  - Apply AUTH (or a tiny pre-auth allow-list) on the *command name* as soon as argv[0] is known, before reading remaining bulks — or cap `argc * max_bulk` (e.g. 512MiB total).
  - Treat only `blen == -1` as null bulk; any other negative length is a protocol error.
  - Do not accept further data on a connection that has not AUTHed beyond a few kilobytes.
- **Status**: open

### Finding 2: Protected-mode loopback check is a substring match (`::1` / `127.0.0.1`)
- **Severity**: critical
- **Category**: A01:2021 Broken Access Control (protected-mode bypass)
- **Location**: `lib/server.mko:497-503`, `lib/server.mko:651-657`, `lib/main.mko:23-28`
- **Description**: With default `--bind 0.0.0.0`, empty `--requirepass`, and `--protected-mode yes` (the compiled defaults), the only remote deny is:

  ```
  peer_is_local: str_contains(p, "127.0.0.1") or str_contains(p, "::1")
  ```

  `str_contains` is not an IP parse. Any peer string that embeds those byte sequences is treated as local, after which `authed` is forced to 1 because `str_len(pass) == 0` (`lib/server.mko:664-666`). IPv6 compressed forms commonly contain `::1` as a substring of a larger group: `2001:db8::1`, `2001:db8::10`, `fe80::1:2`, `2001:db8::1fff`, `[2001:db8::1234]:12345` all match `::1`. Binding `::` / `::0` (documented `--bind ADDR`) makes this reachable. Empty `tcp_peer_addr` fails closed (good); expanded IPv6 loopback `0:0:0:0:0:0:0:1` would be *denied* (fail-closed false negative), which shows the check is not an actual loopback test.
- **Impact**: Full unauthenticated read/write of the store from the network: `GET`/`SET`/`KEYS`/`FLUSHALL`, plus AOF writes if `--appendonly yes`. This is the Redis 3.2 protected-mode bypass class, but easier — no need to hit exactly 127.0.0.1.
- **Reproduction**:
  1. `./bonodis --bind :: --port 6379` (defaults: no password, protected-mode on).
  2. From a host whose IPv6 address string contains `::1` (most addresses with a compressed group starting with `1`):
     ```
     redis-cli -h <victim> PING     # PONG, not DENIED
     redis-cli -h <victim> FLUSHALL # +OK
     redis-cli -h <victim> SET pwned 1
     ```
  3. Contrast: IPv4 `8.8.8.8:12345` does not contain `127.0.0.1` and is correctly denied — the bug is the IPv6 substring, not the feature existing.
- **Remediation**: Parse the peer as an IP (strip `[]` and port). Allow only `127.0.0.0/8`, `::1`, and IPv4-mapped `::ffff:127.0.0.0/8`. Do not use `str_contains`. If `tcp_peer_addr` is unparsable, deny. Consider defaulting `--bind` to `127.0.0.1`.
- **Status**: open

---

### Finding 3: `MULTI` / `DISCARD` / `EXEC` skip AUTH; transaction queue is unbounded
- **Severity**: high
- **Category**: A07:2021 Identification and Authentication Failures
- **Location**: `lib/server.mko:688-736` vs AUTH gate at `lib/server.mko:517-520`
- **Description**: `MULTI`, `DISCARD`, and `EXEC` are handled in `handle_conn` *before* `handle_one`. There is no `authed` check, no max-queue, and no max-MULTI-depth. While `multi == 1`, every subsequent command is `encode_array`’d into `queued` and acknowledged `+QUEUED` — including `SET`/`FLUSHALL`/`AUTH` — without consulting `requirepass`. `EXEC` then calls `handle_one` per entry (so `SET` still returns `NOAUTH` if the password was never satisfied), but the damage is already done in RAM. Redis itself returns `NOAUTH` for `MULTI` when `requirepass` is set.
- **Impact**: Unauthenticated memory exhaustion (queue millions of encoded commands). `EXEC` of a huge queue builds a second copy as a RESP array of `NOAUTH` errors (or `PONG`s — `PING` is pre-auth). Does **not** by itself write keys unless `AUTH` is also queued with the correct password (legitimate) or `requirepass` is empty (Finding 2).
- **Reproduction**:
  ```
  # no AUTH
  printf '*1\r\n$5\r\nMULTI\r\n' | nc host 6379
  # expect +OK, not -NOAUTH
  # then loop:
  printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n'
  # each returns +QUEUED; RSS grows
  ```
- **Remediation**: Run `MULTI`/`DISCARD`/`EXEC` through `handle_one` (or the same AUTH allow-list). Cap `len(queued)` (Redis `max-multi-bulk`). Do not queue commands that would be `NOAUTH` if executed now.
- **Status**: open

### Finding 4: One OS thread per connection, no `maxclients` / idle timeout
- **Severity**: high
- **Category**: A04:2021 Insecure Design / C10K, fd exhaustion
- **Location**: `lib/server.mko:749-760`, `lib/server.mko:651-746`
- **Description**: `accept_loop` `detach`es `handle_conn` for every accepted fd with no cap, no per-connection read timeout (`tcp_set_timeout` is only on the listen fd, line 750), and no write timeout. When `--requirepass` is set, protected-mode is skipped, so the entire Internet can open connections that each occupy a thread, an fd, and an unbounded `buf`. Slowloris (connect, trickle a byte, never read replies so `tcp_write_all` blocks) pins those threads forever.
- **Impact**: Process/thread-table exhaustion, `EMFILE`, and unresponsiveness for legitimate clients. Pre-auth: attacker only needs the open port, not the password.
- **Reproduction**:
  ```
  # against --requirepass secret, from remote
  for i in $(seq 1 20000); do nc host 6379 </dev/null & done
  # or hold sockets open without sending data
  ```
  Observe thread count / fds climb; new `redis-cli PING` hangs or fails.
- **Remediation**: `maxclients` (Redis default 10000) with `-ERR max number of clients reached`. Idle and query timeouts. Prefer a bounded worker pool over unbounded `detach`. Close unauthenticated connections that do not `AUTH` within N seconds.
- **Status**: open

### Finding 5: `SCAN` is a full `KEYS` broadcast; glob matching is exponential and recursive
- **Severity**: high
- **Category**: A04:2021 / CPU DoS, stack overflow
- **Location**: `lib/server.mko:212-214`, `lib/server.mko:234-265`, `lib/store.mko:903-922`, `lib/glob.mko:9-36`
- **Description**: `dispatch` implements `SCAN` by `broadcast(..., ["KEYS", pat])` then slicing the merged array. Every `SCAN` (and `SCAN MATCH`) walks **all keys on all shards**, runs `glob_match`, and materializes the full result — the opposite of Redis `SCAN` incremental semantics. `glob_at` recurses on every `*` (loop `k = si..=sn`) and on every `?`/literal. Pattern `*a*a*a*…*b` against a long run of `a` is catastrophic backtracking. A pattern of tens of thousands of `?` recurses once per byte and will blow the stack. `KEYS` is similarly broadcast. `COUNT` is applied *after* the full collect (`lib/server.mko:249-259`) and is unbounded.
- **Impact**: One authenticated `SCAN`/`KEYS` stalls every shard worker (16). Concurrent `wait_reply` callers spin up to 5s each (`lib/server.mko:5-16`). Process crash on deep recursion. Clients and proxies that replaced `KEYS` with `SCAN` for safety are unprotected. Combined with Finding 2 this is pre-auth.
- **Reproduction**:
  ```
  SET aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa x
  KEYS *a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b
  # or
  SCAN 0 MATCH *a*a*a*a*a*a*a*a*a*a*a*a*b COUNT 10
  ```
  Shard CPU pegs; other commands on those shards return `-ERR timeout` after ~5s; 16 sequential waits can stretch toward 80s for a broadcast.
  Stack crash: `KEYS` with a 100k-character pattern of `?` against a 100k-character key.
- **Remediation**: Implement real cursor `SCAN` per shard with a bounded work quantum. Iterative glob (or explicit depth/step caps). Hard-cap `COUNT`. Consider renaming/refusing `KEYS` in production or requiring an explicit dangerous-command flag.
- **Status**: open

### Finding 6: Cross-shard `MSETNX` / `RENAME` are TOCTOU; `WATCH` is a silent no-op
- **Severity**: high
- **Category**: A04:2021 / race (double-claim), broken optimistic locking
- **Location**: `lib/server.mko:311-339` (`MSETNX`), `lib/server.mko:360-403` (`RENAME`), `lib/server.mko:641-643` (`WATCH`/`UNWATCH`)
- **Description**: `MSETNX` first `EXISTS`es each key across shards, then `SET`s them in a second pass with no lock, no MULTI, and no rollback. Two clients can both observe “missing” and both write. Cross-shard `RENAME` is `EXISTS`(dest) / `GET`(src) / `SET`(dest) / `DEL`(src). Window: dest can appear on both shards; dest can be overwritten after `RENAMENX` checked absence; src can be lost if `SET` works and `DEL` times out (`wait_reply` 5s). Non-string cross-shard rename is rejected, but the string path is not atomic. `WATCH`/`UNWATCH` always `+OK` and do not record versions; `EXEC` never fails `-EXECABORT` for watched keys. README discloses WATCH is ignored; Redis clients still issue it for compare-and-set.
- **Impact**: Lost uniqueness (`MSETNX` used as a reserve/lock), lost updates, duplicated or dropped keys. Any drop-in app using `WATCH`/`MULTI`/`EXEC` for atomicity has no protection. This is the “double-spend” class for a shared store.
- **Reproduction** (`MSETNX`):
  ```
  # two clients, keys hashing to different shards
  # C1 and C2 simultaneously: MSETNX {u1}a 1 {u2}b 1
  # both can return :1
  ```
  (`RENAMENX`): between C1’s `EXISTS dest == 0` and `SET dest`, C2 `SET dest`. C1 still `+OK`/`:1` and overwrites.
  (`WATCH`): `WATCH k; GET k; MULTI; SET k v2; EXEC` always executes even if `k` changed.
- **Remediation**: For same-shard keys, run `MSETNX`/`RENAME` inside the shard (already done when `s1 == s2`). For cross-shard, reject (like the non-string rename path) or use a two-phase commit with shard-side locks. Implement `WATCH` versioning or return an error (`ERR WATCH is not supported`) instead of `+OK`.
- **Status**: open

### Finding 7: AOF replay always executes on DB 0 (logical DB isolation break)
- **Severity**: high
- **Category**: A04:2021 / data isolation
- **Location**: `lib/server.mko:644-647` (WAL payload is raw argv), `lib/server.mko:763-773` (`dispatch(..., 0, argv)`), `lib/resp.mko:233-267` (`SELECT` is not a write)
- **Description**: Successful writes are appended as `encode_array(argv)` with no DB tag. `SELECT` is local-only and not `is_write_cmd`. `replay_aof` always calls `dispatch(..., db=0, argv)`. After a crash/restart, every persisted key from DBs 1–15 is applied to DB 0. `FLUSHDB` in the AOF also flushes DB 0 regardless of the original connection DB.
- **Impact**: Apps that use `SELECT` for tenancy (public DB 0 vs secrets in DB 1, or one DB per customer) leak and mix data on recovery. A malicious/local AOF that contains `FLUSHALL`/`SET` is executed with server privilege and no AUTH (expected for AOF, but combined with DB collapse it poisons the *default* DB).
- **Reproduction**:
  ```
  ./bonodis --appendonly yes --dir ./data
  redis-cli SELECT 1
  redis-cli SET secret hunter2
  redis-cli SELECT 0
  redis-cli GET secret   # nil
  # restart
  redis-cli GET secret   # hunter2  (now in DB 0)
  redis-cli SELECT 1
  redis-cli GET secret   # nil
  ```
- **Remediation**: Prefix each WAL record with the DB (or emit `SELECT` before writes, matching Redis AOF). Replay must restore `SELECT` state. Refuse to load an AOF that is not owner-read-only (`0600`).
- **Status**: open

### Finding 8: No `maxmemory`; `APPEND` / collections grow without bound
- **Severity**: high
- **Category**: A04:2021 / memory exhaustion
- **Location**: `lib/store.mko:628-644` (`APPEND`), `lib/store.mko:1018-1041` (`HSET`), `lib/store.mko:1244-1263` (`LPUSH` copies the whole list), plus absence of any maxmemory in `lib/main.mko` / `lib/server.mko`
- **Description**: Incoming bulks are capped at 32MiB *per argument*, but stored values are not. Repeated `APPEND k <32MiB>` grows one string past the cap. Hashes/lists/sets/zsets have no cardinality limit. `LPUSH` uses `slice_pre` (full copy) so n pushes are O(n²) CPU as well as O(n) RAM. There is no eviction policy.
- **Impact**: Authenticated client (or anyone, if no password / Finding 2) drives the process to OOM. A Redis drop-in is expected to have `maxmemory` + policy; without it the kernel OOM killer is the only brake.
- **Reproduction**:
  ```
  AUTH secret
  # loop: APPEND k <32MiB blob>
  INFO memory   # used_memory climbs until death
  ```
- **Remediation**: `maxmemory` with reject / allkeys-lru. Cap single-string size on `APPEND`/`SET`. Cap list/hash/set/zset length. Make `LPUSH` O(1).
- **Status**: open

### Finding 9: `HELLO` succeeds without validating `AUTH` and claims RESP3
- **Severity**: high
- **Category**: A07:2021 Identification and Authentication Failures
- **Location**: `lib/server.mko:517-520` (HELLO in pre-auth allow-list), `lib/server.mko:565-574`, `lib/server.mko:470-486`, `lib/lib.mko:9` (`PROTO_VER = "7.2.4"`)
- **Description**: Redis 6+ clients (`ioredis`, `go-redis`, `redis-py`) send `HELLO 3 AUTH <user> <pass>` and treat a map reply as “authenticated, proto negotiated”. Bonodis: (1) allows `HELLO` with `authed == 0`; (2) never reads `AUTH`/`SETNAME` subarguments; (3) returns a successful RESP2 array of pairs including `version=7.2.4`, `proto=3` even when proto 3 was requested; (4) leaves `authed` unchanged. Wrong password still gets the success map (not `-WRONGPASS`). `PING` is also pre-auth (`lib/server.mko:518`), unlike Redis `requirepass` (which `NOAUTH`s `PING`).
- **Impact**: Not a direct key-read bypass (subsequent `SET` still `NOAUTH` if `requirepass` is set). It *is* a false-success oracle: scanners and clients believe they are talking to Redis 7.2.4 and that credentials were accepted. Wrong-password HELLO cannot be distinguished from right-password HELLO. Claiming `proto=3` while encoding RESP2 can desynchronize RESP3 clients (they will parse the next `+OK`/`$` as RESP3 types).
- **Reproduction**:
  ```
  redis-cli --pass WRONG HELLO 3 AUTH default WRONG
  # Bonodis: array map, not WRONGPASS
  redis-cli --pass WRONG SET k v
  # -NOAUTH  (so not a data bypass)
  ```
  Compare Redis 7: `HELLO 3 AUTH default WRONG` → `-WRONGPASS`.
- **Remediation**: Parse `HELLO … AUTH user pass` with the same verifier as `AUTH`. On failure return `-WRONGPASS` and do not emit the map. Do not advertise `proto:3` unless RESP3 is actually spoken. Remove `PING` from the pre-auth allow-list (keep `AUTH`, `HELLO`, `QUIT` only).
- **Status**: open

### Finding 10: `wait_reply` busy-polls 20k times/sec for 5s per shard wait
- **Severity**: high
- **Category**: A04:2021 / CPU DoS
- **Location**: `lib/server.mko:5-16`, used from `lib/server.mko:27-30` and every `broadcast` wait
- **Description**: Missing cmap entries cause `sleep_us(50)` in a 100000-iteration loop (5s of ~20,000 wakeups). `MGET`/`DEL`/`MSET` call this once per key serially. `KEYS`/`SCAN`/`FLUSHALL` call it once per shard. Timed-out waiters return `-ERR timeout` *without* deleting a late `cmap_set`, so the reply is leaked in `replies` forever (`lib/server.mko:7-11` only `cmap_del` on hit).
- **Impact**: One slow/blocked shard (Finding 5 glob, or a full channel) turns every in-flight command into a 5s CPU spin. Timeouts leak cmap entries (unbounded metadata growth). An authenticated (or pre-auth MULTI/PING) client can issue many concurrent commands to multiply cores of polling.
- **Reproduction**: Block a shard with Finding 5’s glob, then from N other connections issue `GET k`. Each handler thread sits in the poll loop; `top` shows Bonodis at 100% × N. After 5s, `INFO`/`cmap` equivalent: orphaned ids remain (no `cmap_del`).
- **Remediation**: Blocking recv, condvar, or channel per request id. On timeout, mark the id cancelled and drop late replies. Bound in-flight requests per connection to 1 (Redis does).
- **Status**: open

---

### Finding 11: `CONFIG SET` always returns `+OK` and never mutates `requirepass`
- **Severity**: medium
- **Category**: A05:2021 Security Misconfiguration
- **Location**: `lib/server.mko:597-613`
- **Description**: `CONFIG GET` returns a fixed trio (`port`, `databases`, `appendonly`) and never `requirepass`. Any other `CONFIG` subcommand, including `CONFIG SET requirepass …`, `CONFIG SET protected-mode no`, `CONFIG SET dir`, returns `+OK` with no side effects. `pass` is a by-value argument into `handle_conn` anyway, so a future naive mutation of a global would still not affect live connections.
- **Impact**: Operators and automation (`CONFIG SET requirepass <rotated>`) believe the password changed. Old password keeps working; new password is `WRONGPASS`. False sense that protected-mode or bind was tightened at runtime. Not an attacker “disable AUTH” gadget *today* (it does not clear the password either), but it is a broken security control with Redis-compatible syntax.
- **Reproduction**:
  ```
  ./bonodis --requirepass old
  redis-cli -a old CONFIG SET requirepass new   # +OK
  redis-cli -a new PING   # NOAUTH/WRONGPASS
  redis-cli -a old PING   # PONG
  ```
- **Remediation**: Implement `CONFIG SET requirepass` with immediate effect on the AUTH comparator (and document that existing authed conns stay authed, matching Redis), or return `-ERR unsupported CONFIG SET`. Never `+OK` a no-op for security-relevant keys.
- **Status**: open

### Finding 12: `requirepass` compared with non-constant-time `str_eq`; no AUTH throttle
- **Severity**: medium
- **Category**: A07:2021 / CWE-208 timing oracle, brute force
- **Location**: `lib/server.mko:540-551`
- **Description**: `AUTH pass` and `AUTH user pass` use `str_eq(argv[i], pass)`. Usernames are ignored (any user works if the password matches). Failed AUTH is immediate `WRONGPASS` with no Redis-style delay, no per-peer counter, no connection close after N failures. Combined with Finding 4 (unlimited connections) this is an online guessing surface. Empty `requirepass` makes `AUTH` always succeed (`str_len(pass) == 0` short-circuit).
- **Impact**: Password length and prefix leak via `str_eq` short-circuit (network jitter makes this harder but not imaginary on LAN/colocated). Unlimited guesses at pipeline speed. `--requirepass` on the command line (`lib/main.mko:54-56`) is also visible in `ps` to local users.
- **Reproduction**: Time `AUTH a`, `AUTH s`, `AUTH se`, … against `--requirepass secret` on localhost; compare failed-AUTH QPS vs Redis 7 (which sleeps on failure). `ps aux | grep bonodis` shows the secret.
- **Remediation**: Constant-time compare of equal-length buffers (hash both sides with a server secret if lengths must stay hidden). Delay / disconnect on `WRONGPASS`. Prefer `BONODIS_REQUIREPASS` env over argv. Reject empty passwords when `--requirepass` is passed.
- **Status**: open

### Finding 13: RESP simple-string injection via CRLF in command names
- **Severity**: medium
- **Category**: A03:2021 Injection (protocol smuggling)
- **Location**: `lib/resp.mko:51-56`, `lib/resp.mko:79-81`, `lib/resp.mko:63-65`; unknown-command path `lib/store.mko:506`
- **Description**: Bulk strings may contain `\r\n` (`lib/resp.mko` tests this). `r_err` / `r_unknown` / `r_arity` splice `argv[0]` into a `-…\r\n` simple string with no sanitization. A command name `FOO\r\n+OK\r\n` yields two (or more) RESP values on the wire.
- **Impact**: Shared-connection proxies, multiplexers, or naive line parsers can desynchronize and mix replies between clients (response smuggling). Not a store read by itself; it is a protocol-confusion primitive.
- **Reproduction**:
  ```
  # argv[0] = "x\r\n+PONG\r\n"
  *1\r\n$11\r\nx\r\n+PONG\r\n\r\n
  # reply contains a second +PONG line inside the error
  ```
- **Remediation**: Encode errors as bulk strings, or strip/reject CR/LF in simple-string payloads. Redis itself also has this class of bugs historically; for a new parser, reject non-ASCII command names.
- **Status**: open

### Finding 14: `SRANDMEMBER` with large negative count allocates without bound
- **Severity**: medium
- **Category**: A04:2021 / memory DoS
- **Location**: `lib/store.mko:1656-1664`
- **Description**: Negative count means “with replacement”. The code does `n = 0 - n` then loops `n` times, appending a random member each time. `int_ok` does not cap `n`. A single `SRANDMEMBER key 2000000000` (negative) tries to build a ~2e9-element array. Positive counts are clamped to set size; negatives are not.
- **Impact**: Authenticated (or no-auth) client OOM. Same pattern is a standard Redis footgun; Redis at least has `maxmemory` (Finding 8).
- **Reproduction**: `SADD s a` then `SRANDMEMBER s -500000000`.
- **Remediation**: Cap `|count|` (and reply size) to proto-max-bulk / maxmemory. Fail with `-ERR` above the cap.
- **Status**: open

### Finding 15: Default bind `0.0.0.0` with empty password
- **Severity**: medium
- **Category**: A05:2021 Security Misconfiguration
- **Location**: `lib/main.mko:22-28`, `README.md` flags table
- **Description**: Defaults are `host = "0.0.0.0"`, `pass = ""`, `protected = 1`. Redis 3.2 made the same choice and then spent a decade cleaning up exposed instances. Here protected-mode is Finding 2, so the default posture is “listen on all IPv4 addresses and hope peer-string matching works.” `make run` binds loopback (good); the binary defaults do not.
- **Impact**: Accidental Internet exposure of an unauthenticated data store whenever protected-mode mis-classifies a peer or is set to `no`.
- **Reproduction**: `./bonodis` with no flags; `ss -lnt | grep 6379` shows `*:6379`.
- **Remediation**: Default `--bind 127.0.0.1`. Require an explicit `--protected-mode no` *and* a non-loopback bind to listen externally. Refuse to listen on a non-loopback address when `requirepass` is empty, regardless of the protected-mode flag.
- **Status**: open

### Finding 16: Untrusted AOF is executed as the server (no command allow-list)
- **Severity**: medium
- **Category**: A08:2021 Software and Data Integrity Failures
- **Location**: `lib/persist.mko:28-50`, `lib/server.mko:763-773`, `lib/main.mko:97-101`
- **Description**: `wal_load` pulls every record into RAM then `parse_cmd` + `dispatch` without filtering to write commands. A local user who can write `dir/appendonly.aof` (default `./appendonly.aof`) can plant `FLUSHALL`, arbitrary `SET`s, or a `KEYS` glob that hangs startup (Finding 5) before `accept_loop` runs (`replay_aof` is synchronous in `serve` prior to accepting, `lib/server.mko:832-836`). There is no WAL checksum visible at this layer. `wal_load` itself is unbounded (entire history as `[]string`).
- **Impact**: Persistence-file attacker gets full data-plane control and a startup hang/crash. Restoring an AOF from a backup or a shared volume is an execution primitive, not just data import. Combined with Finding 7, planted keys land in DB 0.
- **Reproduction**: With the server stopped, append a RESP `FLUSHALL` (or `SET pwn 1`) record the WAL reader will return; start with `--appendonly yes --dir …`. Dataset is flushed/poisoned before any TCP AUTH.
- **Remediation**: Integrity-protect WAL records. Replay only `is_write_cmd` names. File mode `0600` and refuse world-writable `--dir`. Stream replay instead of loading all records.
- **Status**: open

### Finding 17: Parser treats any negative bulk length as empty string
- **Severity**: medium
- **Category**: A04:2021 / protocol confusion
- **Location**: `lib/resp.mko:203-207`
- **Description**: After `int_ok`, `blen < 0` appends `""` and continues — including `$-2`, `$-999`, and overflow-to-negative if `parse_int` wrapped. Redis allows only `$-1` (null bulk) inside arrays for commands; other negatives are proto errors. This also skips the 32MiB cap (Finding 1).
- **Impact**: Command arity/meaning shifts (`SET k <null>` becomes `SET k ""`). Can be used to sneak extra empty arguments past client assumptions. If `parse_int` on a huge digit string yields a negative, the bulk-size cap is bypassed in a different way (depends on Mako `parse_int`; the `< 0` branch is still wrong even without overflow).
- **Reproduction**: `*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$-2\r\n` — Bonodis should `-ERR protocol error`; instead it may `SET k` to empty (if AUTH not required).
- **Remediation**: `blen < -1` or `blen < 0 && blen != -1` → protocol error. Range-check `parse_int` against `[0, max_bulk] ∪ {-1}`.
- **Status**: open

### Finding 18: Inline protocol and pipelined mix have no framing cap
- **Severity**: medium
- **Category**: A04:2021
- **Location**: `lib/resp.mko:135-146`, `lib/resp.mko:148-160`, `lib/server.mko:675-686`
- **Description**: First byte `*` selects RESP array; anything else is inline until CRLF. A client can send a 1-byte-at-a-time inline line of arbitrary length, or concatenate inline + RESP in one buffer (`PING\r\n*3\r\n…`). Incomplete inline is `st == 0` (need more), so `buf` grows (Finding 1). There is no “must start with `*` once we have seen RESP” mode, which Redis uses to avoid inline after a binary payload.
- **Impact**: Complements Finding 1; also a desync risk if a bulk payload’s first byte is not consumed correctly (the bulk CRLF check at `lib/resp.mko:216-218` is good for the RESP path only).
- **Reproduction**: Send `PING` without `\r\n` and keep appending. Then send `\r\n*3\r\n$3\r\nSET…` on the same connection.
- **Remediation**: Max inline line length (e.g. 64KiB). After the first `*` command on a connection, disable inline (Redis `PROTO_INLINE` vs `PROTO_MULTIBULK`).
- **Status**: open

---

### Finding 19: `SELECT` non-integer silently becomes DB 0
- **Severity**: low
- **Category**: A04:2021 / CWE-20
- **Location**: `lib/resp.mko:5-9` (`int_of` → 0 on parse failure), `lib/server.mko:555-563`
- **Description**: `SELECT xyz` / `SELECT ""` parses as 0 and returns `+OK`, switching the connection to DB 0. Out-of-range numeric indexes are rejected; garbage is not.
- **Impact**: A confused client or injected index lands on DB 0, mixing tenant data with the default DB (worsens Finding 7).
- **Reproduction**: `SELECT nope` → `+OK`; subsequent `GET` reads DB 0.
- **Remediation**: Use `int_ok`; on `ok == 0` return `-ERR invalid DB index`.
- **Status**: open

### Finding 20: `COMMAND` is pre-auth and incomplete; `DUMPKV` is an undocumented data-plane command
- **Severity**: low
- **Category**: A01:2021 / information disclosure
- **Location**: `lib/server.mko:518`, `lib/server.mko:575-580`, `lib/store.mko:503-505`, `lib/store.mko:1888-1891`
- **Description**: Unauthenticated `COMMAND` / `COMMAND LIST` returns a short name list (not arity/flags). `DUMPKV` is implemented on the shard (`collect_keys`) but omitted from `COMMAND`, so it is a hidden `KEYS *` on shard 0 only (`dispatch` falls through to shard 0 when `len(argv) < 2`, `lib/server.mko:227-231`).
- **Impact**: Recon of the command surface without AUTH. `DUMPKV` leaks key names on shard 0 to anyone who can run commands (AUTH or no-password).
- **Reproduction**: Without AUTH: `COMMAND` returns an array, not `NOAUTH`. With AUTH: `DUMPKV` returns keys; `COMMAND LIST` does not mention it.
- **Remediation**: Remove `COMMAND` from the pre-auth list. Delete `DUMPKV` or require an admin flag. Do not fall through unknown zero-key commands to shard 0 if they are not meant to be public.
- **Status**: open

### Finding 21: Spoofed `redis_version:7.2.4` and hardcoded `os:Darwin`
- **Severity**: low
- **Category**: A05:2021 / security tool confusion
- **Location**: `lib/lib.mko:9`, `lib/server.mko:427-467`, `lib/server.mko:470-486`
- **Description**: `INFO` and `HELLO` advertise Redis 7.2.4. `INFO` always prints `os:Darwin` and `process_id:0`. Vulnerability scanners will apply Redis 7.2.4 CPE logic (or skip Bonodis-specific issues).
- **Impact**: Mis-inventory; false sense that Redis 7.2.4 advisories were patched. Not a direct exploit.
- **Reproduction**: `INFO server` after AUTH (or no password).
- **Remediation**: Advertise `bonodis_version` as the primary version; if `redis_version` must exist for clients, document it as compatibility theatre, not a Redis build.
- **Status**: open

### Finding 22: `--requirepass` and AOF path are local-attacker visible / writable
- **Severity**: low
- **Category**: A02:2021 Cryptographic Failures / sensitive data in process state
- **Location**: `lib/main.mko:54-56`, `lib/main.mko:97-101`
- **Description**: Password is an argv string. AOF path is `dir + "/appendonly.aof"` with `mkdir_all(dir)` and no chmod. Local `ps`, `cgroup` environ, and directory listing expose credentials and the full key history in cleartext RESP.
- **Impact**: Any local user on a shared box reads the password and, if the AOF is created with a permissive umask, the dataset.
- **Reproduction**: `ps` while `--requirepass` is set; `ls -l dir/appendonly.aof` after writes.
- **Remediation**: Env/file-based secret with `0600`. `umask 077` before `wal_open`.
- **Status**: open

---

### Finding 23: `touch_store_methods()` is not a network attack surface
- **Severity**: informational
- **Category**: defense-in-depth note
- **Location**: `lib/store.mko:1978-2044`, called from `lib/server.mko:783`
- **Description**: Startup dummy `Store_*` calls keep native method symbols in the Mako table. They run on a throwaway `Store`, not on shard state, and are not reachable from TCP.
- **Impact**: None for the threat model. Do not treat this as an entry point.
- **Reproduction**: n/a
- **Remediation**: None required. A compile-time keep-alive would be cleaner than runtime mutation.
- **Status**: open

### Finding 24: No TLS, no ACLs beyond a single `requirepass`
- **Severity**: informational
- **Category**: A02:2021 / A01:2021
- **Location**: `README.md` “Not in v0.1”; `lib/server.mko` AUTH block
- **Description**: Documented. All clients share one password; AUTH user is ignored; traffic is plaintext RESP on 6379.
- **Impact**: Network observers recover `AUTH` and payloads. No per-command ACL to stop an authed client from `FLUSHALL`/`CONFIG`/`KEYS`.
- **Reproduction**: Packet-capture `AUTH` / `SET`.
- **Remediation**: TLS (or stunnel in front). Split admin vs data users. At minimum, refuse `FLUSHALL`/`KEYS`/`CONFIG` without an extra flag.
- **Status**: open

### Finding 25: `crc16` / slot hashing is non-cryptographic (expected)
- **Severity**: informational
- **Category**: A02:2021 (not a vuln here)
- **Location**: `lib/crc16.mko:6-57`
- **Description**: CRC16-XMODEM with Redis `{hashtags}` is used only to pick a shard. An attacker can choose keys that collide on one shard (hot-shard DoS) the same way they can on Redis Cluster.
- **Impact**: Traffic concentration on one of 16 workers; not confidentiality.
- **Reproduction**: Keys with the same `{tag}` all hit one shard (`lib/crc16.mko:26-46`).
- **Remediation**: None for compatibility. Optional per-shard max-ops rate limit would blunt hot-shard abuse.
- **Status**: open

---

## Threat-model checklist (explicit)

| Question | Result |
|---|---|
| AUTH bypass via `HELLO`/`COMMAND`/`PING`/`SET` after failed AUTH | `SET` after failed AUTH is still `NOAUTH`. `HELLO`/`PING`/`COMMAND` are pre-auth (Findings 9, 20). `HELLO AUTH` does not set `authed`. |
| Pipelined commands before AUTH completes | Sequential parse in one thread; `AUTH` then `SET` in one packet works as intended. `SET` then `AUTH` does not write. No race. |
| `MULTI` before AUTH | **Yes**, `+OK` / `+QUEUED` without password (Finding 3). `EXEC` still `NOAUTH`s writes. |
| Protected-mode bypass (IPv6 / mapped / empty peer / unix) | IPv6 substring **yes** (Finding 2). Empty peer denied. Unix sockets not implemented. Mapped IPv4 loopback matches `127.0.0.1` (correct). |
| RESP unbounded alloc, overflow, missing CRLF, nested arrays, 32MiB cap | Unbounded `buf` and `argc*blen` (Finding 1). Nested arrays rejected (`!= '$'`). Missing bulk CRLF is proto error (good). Negative lens (Finding 17). |
| Glob recursion / `KEYS *` | **Yes** (Finding 5). |
| WAL path / malicious AOF | **Yes** (Findings 7, 16). |
| `requirepass` timing / empty password | **Yes** (Finding 12). Empty pass = all connections authed. |
| Cross-shard `MSETNX` / `RENAME` / `MULTI` | **Yes** (Finding 6). `MULTI` is not cross-shard atomic either. |
| `wait_reply` busy-loop | **Yes** (Finding 10). |
| One thread per connection | **Yes** (Finding 4). |
| `FLUSHALL` without AUTH | Only if `requirepass` empty (defaults) and protected-mode allows the peer (Finding 2). Not a separate allow-list hole. |
| `CONFIG SET requirepass` | Lies with `+OK`, does not mutate (Finding 11). |
| `touch_store_methods` | Not attacker-reachable (Finding 23). |

---

## Positive observations

- Data commands (`GET`/`SET`/`FLUSHALL`/`CONFIG`/`INFO`/`SELECT`/`ECHO`) go through `handle_one`’s `NOAUTH` check when `requirepass` is non-empty; failed `AUTH` leaves `authed == 0`.
- No `EVAL`/`SCRIPT`/`MODULE`/`SLAVEOF`/`REPLICAOF`/`DEBUG` — the usual Redis pre-auth RCE and replica-of-attacker gadgets are simply not implemented.
- RESP arrays cannot nest; non-`$` elements are protocol errors. Bulk bodies are sliced by length, so values may contain CRLF without splitting commands.
- `argc > 4096` and `blen > 33554432` are rejected (the *product* is the hole, not the absence of any cap).
- `encode_job` is length-prefixed, so keys/values with embedded newlines cannot inject extra job fields into shard workers.
- `CONFIG GET` does not echo `requirepass`. AUTH errors do not echo the supplied password.
- `SELECT` numeric range is limited to `0..15`. Protected-mode **fails closed** on empty peer strings.
- Password is not written to AOF (only data commands with `is_write_cmd`). `QUIT` is allowed pre-auth, matching Redis.
- Startup `touch_store_methods` does not touch live shard maps.

---

## Priority remediations

1. Bound `buf`, `argc * blen`, `MULTI` queue, clients, and `maxmemory`; parse-or-AUTH before allocating 32MiB bulks.
2. Replace `str_contains` loopback detection with real IP checks; default-bind loopback.
3. Put `MULTI`/`EXEC` behind AUTH; implement or hard-error `WATCH`.
4. Stop implementing `SCAN` as `KEYS`; cap glob.
5. Persist DB id on every AOF record; do not `+OK` no-op `CONFIG SET requirepass`.
