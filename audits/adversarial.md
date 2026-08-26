## Adversarial Review: Bonodis

### Summary

Reviewed `lib/resp.mko`, `lib/store.mko`, `lib/server.mko`, `lib/persist.mko`, `lib/glob.mko`, `lib/crc16.mko`, `lib/main.mko`, and all `lib/*_test.mko` files. Focus was Redis drop-in correctness: crashes, data loss, type errors, shard merge, MULTI/EXEC, persistence, and tests that would hide those bugs.

**Checked and not filed as bugs**

- RESP bulk extraction is length-prefixed. Binary payloads that contain `\r\n` parse correctly (`parse_resp_array` at `lib/resp.mko:202-221`; covered by `TestRespBulkBinary`).
- `tcp_read` 64 KiB chunks are assembled in `handle_conn`'s inner parse loop (`lib/server.mko:671-686`). A bulk larger than one read completes once enough bytes arrive.
- Same-shard `SET` overwrites hashes/lists/sets (Redis does this). Empty hashes/sets/zsets/lists are dropped on last delete/pop (`HDEL`/`SREM`/`ZREM`/`LPOP`/`LTRIM`).
- `FLUSHDB` vs `FLUSHALL` prefix logic is correct: `FLUSHDB` keeps `kdb(ik) == db`, `FLUSHALL` drops every key on the shard (`lib/store.mko:983-1002`), then `broadcast` hits all shards.
- `SELECT` namespacing via `"/" + db + "/" + key` does not collide for dbs 0–15.
- WAL replay runs *before* `accept_loop` is kicked (`lib/server.mko:832-836`), so there is no live-traffic race during load. The persistence bugs below are about *what* is logged/replayed, not a replay/live race.
- CRC16 / `{hashtag}` routing matches Redis Cluster KEYSLOT (`crc16("123456789") == 12739`).

Tests never exercise MULTI/EXEC, SCAN, RENAME, MSETNX, AOF, KEEPTTL, cross-shard merge, LPOP count, SET-on-other-types, EXPIRE 0, or ZADD of non-floats. Several passing tests use `str_contains` / `str_has_prefix` and would not catch ordering or nil-slot bugs.

---

### Issue 1 -- Severity: bug
- File: `lib/server.mko:644-647`, `lib/server.mko:763-773`, `lib/resp.mko:233-267`
- Description: AOF records are the raw RESP command only. `SELECT` is not a write command, and `replay_aof` always calls `dispatch(..., 0, argv)`. Every write that happened on DB 1–15 is restored into DB 0. `FLUSHDB` on DB 1 is replayed as `FLUSHDB` on DB 0 and wipes the wrong database. This is silent data corruption on restart, not a missing feature.
- Suggestion: Log an absolute DB (e.g. prepend `SELECT` or a db field in the WAL record) and replay into that DB. Relative `EXPIRE`/`SET EX` should be rewritten as `PEXPIREAT` so TTLs do not stretch on restore.
- Status: open

### Issue 2 -- Severity: bug
- File: `lib/server.mko:360-403`
- Description: Cross-shard `RENAME`/`RENAMENX` is `GET` + `SET` + `DEL`. Three independent failures:

  1. **Silent data loss on unexpected GET reply.** Only `$-1` and `-WRONGTYPE` are handled. `wait_reply` timeout is `-ERR timeout\r\n`. That takes the fallback path: `int_of("ERR timeout")` is 0, `val` becomes `""`, destination is `SET` to empty, source is `DEL`eted. The original value is gone.

  2. **TTL is dropped.** `GET` does not return expiry. Destination is a bare `SET`.

  3. **Not atomic.** Another client can observe both keys, or `RENAMENX`'s `EXISTS` check can race with a writer and still overwrite (the following `SET` is not `NX`).

  Non-string values are *not* silently lost: they return `ERR rename across shards is only supported for string values`. The timeout/TTL cases are the real data-loss bugs.
- Suggestion: Fail closed on any non-bulk GET reply (do not DEL). Copy `PTTL` onto the destination (`PEXPIRE`). Same-shard rename already copies type+TTL (`lib/store.mko:862-900`); use that path whenever `{hash tags}` land both keys together, and refuse cross-shard rename rather than half-applying it.
- Status: open

### Issue 3 -- Severity: bug
- File: `lib/store.mko:212-230`, `lib/store.mko:602-611`
- Description: `SET … KEEPTTL` always strips the TTL. `cmd_set` calls `drop_key` (which `delete`s `self.expire`) and never saves/restores `expire[ik]`. The `keepttl` flag only skips *installing a new* expire. Redis `SET KEEPTTL` must retain the previous PTTL.
- Suggestion: Read `expire[ik]` before `drop_key`. If `keepttl == 1` and an expire existed, write it back after the new string is stored. `KEEPTTL` combined with `EX`/`PX`/`EXAT`/`PXAT` should be a syntax error, matching Redis 7.
- Status: open

### Issue 4 -- Severity: bug
- File: `lib/server.mko:267-308`, `lib/store.mko:682-701`
- Description: Redis `MGET` returns nil for missing keys *and* for non-string keys; it never returns `WRONGTYPE`. The store implementation gets this right (`cmd_mget` treats `t != T_STR` as a miss). The server path never uses it: `dispatch_mget` issues per-key `GET`. A hash/list/set in the key list makes the whole `MGET` return `-WRONGTYPE`. Clients that `MGET` mixed keyspaces (or that probe existence this way) break.
- Suggestion: Dispatch `MGET` as `MGET` to each shard (group keys by shard, preserve request order) or map `WRONGTYPE` from `GET` to a nil slot.
- Status: open

### Issue 5 -- Severity: bug
- File: `lib/server.mko:311-340`, `lib/server.mko:342-357`
- Description: `MSET` / `MSETNX` / multi-key `DEL` are split into one shard job per key. They are not atomic even when every key hashes to the same shard: another client's command can run on that shard between jobs. Extra `MSETNX` holes:

  - Existence is checked with `EXISTS`, then applied with plain `SET` (not `SET NX`). A key created in the window is overwritten and `MSETNX` still returns `:1`.
  - A timeout/`-` on a later `SET` leaves a partial write. Redis `MSETNX` is all-or-nothing.

  Store-level `cmd_mset` *is* atomic on one shard (`lib/store.mko:704-726`) but the TCP path never sends a whole `MSET` as one job.
- Suggestion: Partition pairs by shard and send one `MSET`/`MSETNX` job per shard. For true cross-shard atomicity, reject `MSETNX` that spans shards (or run a two-phase check-and-set under a global lock). Never turn `MSETNX` into unconditional `SET`.
- Status: open

### Issue 6 -- Severity: bug
- File: `lib/server.mko:688-735`
- Description: MULTI/EXEC diverges from Redis in ways that drop queued work and lie to clients:

  1. **Nested `MULTI` is `+OK` and clears `queued`.** Redis: `-ERR MULTI calls can not be nested`. Previously queued commands are silently discarded (`lib/server.mko:688-693`).
  2. **`DISCARD` without `MULTI` is `+OK`.** Redis: `-ERR DISCARD without MULTI` (`lib/server.mko:694-698`).
  3. **`MULTI`/`DISCARD`/`EXEC` bypass the `NOAUTH` gate** in `handle_one`. Redis rejects `MULTI` with `NOAUTH`. Queued writes still fail at `EXEC` (no auth bypass), but the handshake is not drop-in.
  4. Failed `AUTH` inside `EXEC` forces `authed = 0` even if the connection was already authenticated (`lib/server.mko:545, 551`). Later commands in the same `EXEC` become `NOAUTH`. Redis keeps the previous user on a failed `AUTH`.
- Suggestion: Nested `MULTI` → error, leave the queue intact. `DISCARD`/`EXEC` without `MULTI` → Redis errors. Run `MULTI`/`EXEC`/`DISCARD` through the same AUTH check as other commands. Failed `AUTH` must not clear a successful session.
- Status: open

### Issue 7 -- Severity: bug
- File: `lib/server.mko:660-686`, `lib/resp.mko:148-160`, `lib/resp.mko:187-212`
- Description: `buf = buf + chunk` has no cap. `parse_cmd` returns `st == 0` (need more) without limiting `buf`. Bulk bodies are rejected above 32 MiB *after* the `$len` line is complete, but:

  - Inline / array headers never CRLF-terminated (`*` then 1 GB of junk, or telnet without `\r`) grow without bound.
  - A declared `$33554432` bulk that is dribbled in still holds 32 MiB per connection, times many connections.

  Slowloris is a memory kill. `tcp_read` looping is fine; the missing max-buffer and idle-parse timeout are not.
- Suggestion: Cap `str_len(buf)` (and declared `blen * argc`) per connection; close with a protocol error. Add a read/parse deadline for incomplete frames.
- Status: open

### Issue 8 -- Severity: bug
- File: `lib/glob.mko:19-27`, `lib/server.mko:33-70`, `lib/server.mko:92-107`, `lib/server.mko:788-804`
- Description: `glob_at` on `*` walks every remaining offset and recurses. Pattern `*a*a*a*a*…*b` against a long non-matching key is exponential. `KEYS`/`SCAN` run that on every key **on the shard worker**.

  The router is a single thread that blocking-`send`s into per-shard channels of size 1024, fed by a shared inbox of 4096. If shard 0 is stuck in glob backtracking, `s0.send` blocks, the router stops draining the inbox, and jobs for shards 1–15 never run. Combined with `wait_reply`'s 5s poll, this is a whole-server stall, not just a slow `KEYS`.
- Suggestion: Bound glob matching (time or star count) and fail the command. Make router sends non-blocking or use per-shard inboxes so one stuck shard cannot HOL-block the others.
- Status: open

### Issue 9 -- Severity: bug
- File: `lib/server.mko:5-16`, `lib/store.mko:1972-1973`
- Description: `wait_reply` polls `cmap_has` every 50 µs up to 100000 times (5 seconds), then returns `-ERR timeout` **without deleting the id**. `shard_loop` still `cmap_set`s the reply later. Ids only increase (`atomic_add`), so the entry is leaked forever. A client that disconnects mid-wait does not cancel the waiter; the conn thread sits in the poll loop until timeout or reply. Under load this is both a CPU spin (20k wakeups/s per waiter) and a reply-board leak.

  Timeout replies also feed Issue 2 (RENAME) and Issue 5 (MSETNX `EXISTS` treated as 0 via `parse_int_reply` on a `-` error).
- Suggestion: Park on a per-id cond var / oneshot instead of 50 µs sleep. On timeout, mark the id cancelled and drop late replies. On client close, cancel outstanding ids.
- Status: open

### Issue 10 -- Severity: bug
- File: `lib/store.mko:1685-1705`, `lib/store.mko:1868-1885`, `lib/store.mko:155-188`
- Description: `ZADD` ignores `parse_float`'s result (`let _ = parse_float(argv[i])`) and stores the raw string. `parse_float` returns `0.0` on invalid input and accepts `nan` via `strtod`. Redis rejects non-floats and NaN with `-ERR value is not a valid float`. Non-numeric scores sort as 0; NaN comparisons are never `<`/`==`, so `z_sorted` is not a total order and `ZRANGE`/`ZRANK` become unstable. `ZINCRBY` has the same missing check.
- Suggestion: Reject scores unless they parse as a finite float (allow `+inf`/`-inf` to match Redis). Do not store the original token if parsing failed.
- Status: open

### Issue 11 -- Severity: bug
- File: `lib/store.mko:662-679`, `lib/store.mko:1203-1227`, `lib/store.mko:560-568`, `lib/store.mko:801`
- Description: Mako `int` is `int64_t` and wrapping add is the default. `INCR`/`INCRBY`/`DECR`/`HINCRBY` do `cur + delta` with no overflow check. Redis returns `-ERR increment or decrement would overflow` at the signed 64-bit boundary; Bonodis wraps (e.g. `9223372036854775807` + 1 → `INT64_MIN`) and persists the bad value.

  The same wrapping hits expire math: `wall_ms() + n * 1000` / `n * mul` for `SET EX` / `EXPIRE` / `EXPIREAT`. A huge TTL can wrap to a past timestamp (immediate delete) or a small future (wrong TTL).
- Suggestion: Use checked add (`safe_add`) and return `r_notint()` / Redis's overflow error. For expires, reject `n <= 0` on `SET EX`/`PX` (Redis 7: `invalid expire time`) and reject overflows rather than storing a wrapped `at`.
- Status: open

### Issue 12 -- Severity: bug
- File: `lib/server.mko:234-265`, `lib/store.mko:932-961`, `lib/store.mko:903-922`
- Description: Server `SCAN` does not use `Store_cmd_scan`. `merge_scan` always `broadcast`s `KEYS`, concatenates, and treats the cursor as an integer offset into that snapshot.

  - **No arity check:** `SCAN` with no cursor does `int_ok(argv[1])` and is an out-of-bounds access (runtime abort), not `-ERR wrong number of arguments`.
  - **Unstable cursor:** `collect_keys` iterates `self.types` with no sort. The next `SCAN` re-runs `KEYS` on every shard. Cursors skip and duplicate keys even with no writes, which is worse than Redis SCAN's rehash caveats.
  - **No shard in the cursor.** Not inherently wrong given the global merge, but it makes the index even more meaningless across calls.
- Suggestion: Reject `len(argv) < 2`. Encode `(shard, offset)` (or a generation + offset) in the cursor and iterate each shard incrementally. Do not implement SCAN as KEYS-and-slice.
- Status: open

### Issue 13 -- Severity: bug
- File: `lib/server.mko:517-521`, `lib/server.mko:565-573`
- Description: With `--requirepass`, `HELLO` is allowed before `AUTH` and does not parse `HELLO … AUTH …`. `authed` is left unchanged (0). redis-py / go-redis / ioredis send `HELLO 3 AUTH default <pass>` and then issue writes; those writes get `NOAUTH`. `HELLO 3` is accepted (`proto != 2 and proto != 3` only) but `hello_reply` is still a RESP2 array of bulks, so RESP3 clients misparse the handshake.
- Suggestion: Match Redis: `HELLO` without AUTH under `requirepass` → `NOAUTH`. Honor `AUTH`/`SETNAME` options. Either reject proto 3 (`NOPROTO`) or actually switch encoding.
- Status: open

### Issue 14 -- Severity: bug
- File: `lib/server.mko:555-563`, `lib/resp.mko:5-10`
- Description: `SELECT` uses `int_of`, which maps parse failure to 0. `SELECT abc` / `SELECT` of an empty string becomes `SELECT 0` and returns `+OK`. Redis returns an error. This is a silent DB switch, not just a bad error string.
- Suggestion: Use `int_ok` and reject `ok == 0` (and still reject `n < 0 || n > 15`).
- Status: open

### Issue 15 -- Severity: bug
- File: `lib/server.mko:172-181`, `lib/server.mko:209-210`
- Description: `RANDOMKEY` broadcasts and `pick_bulk` returns the first non-nil shard reply in shard-index order. If shard 0 has any key, it always wins. Redis picks uniformly among all keys. The per-shard `RANDOMKEY` is random; the merge is not.
- Suggestion: Reservoir-sample across shard replies (or collect all keys and pick), weighted by each shard's `DBSIZE`.
- Status: open

### Issue 16 -- Severity: bug
- File: `lib/store.mko:1629-1669`
- Description: `SRANDMEMBER key count` with `count > 0` returns `slice_skip_take(mems, 0, n)` — the first `n` members of map iteration, every time. Redis returns a random distinct sample. `count < 0` *does* pick randomly (with replacement). The positive-count path is simply wrong.
- Suggestion: Shuffle or sample `n` distinct indices (the `SPOP` count path already attempts a pick; reuse a correct Fisher–Yates).
- Status: open

### Issue 17 -- Severity: bug
- File: `lib/store.mko:253-259`, `lib/store.mko:552-570`, `lib/store.mko:785-800`
- Description: Redis 7 `SET key val EXAT 0` / `PXAT 0` is an invalid expire (or expires immediately because epoch 0 is in the past). Here `SET EXAT 0` sets `at = 0`, and `set_expire_at` treats `at <= 0` as “delete expire”, so the key becomes persistent. `EXPIREAT 0` *does* delete the key (`lib/store.mko:817-820`). Same command family, opposite outcomes. `SET EX 0` / `PX 0` / negative `n` also skip Redis's `invalid expire time` error and install a now/past timestamp.
- Suggestion: Reject non-positive expire options on `SET`. For `EXAT`/`PXAT`, treat `at <= wall_ms()` as immediate delete, consistent with `EXPIREAT`.
- Status: open

### Issue 18 -- Severity: bug
- File: `lib/server.mko:206-207`, `lib/server.mko:157-169`, `lib/store.mko:925-929`
- Description: `KEYS` with no pattern is broadcast as-is. Each shard returns an arity `-ERR`. `merge_arrays` / `parse_array_bulks` only accept replies starting with `*`; errors become empty lists. The client sees `*0\r\n` instead of an arity error. Same swallow happens for a shard `wait_reply` timeout during `KEYS`: that shard's keys are dropped with no error.
- Suggestion: If any shard reply is `-`, return it. Check arity before `broadcast`.
- Status: open

### Issue 19 -- Severity: suggestion
- File: `lib/store.mko:826-844`
- Description: Redis `TTL` on a key that still has 1–999 ms left returns `1` (it rounds up so `0` cannot mean “exists with expire”). `left / 1000` can return `:0` while the key is still live. Clients that treat `TTL == 0` as expired will delete live keys.
- Suggestion: If `left > 0` and `div == 1000`, return at least 1.
- Status: open

### Issue 20 -- Severity: suggestion
- File: `lib/store.mko:1266-1319`, `lib/store.mko:1604-1626`
- Description: Redis `LPOP key -1` / `SPOP key -1` are errors (`value is out of range, must be positive`). Here a negative count makes the `while i < n` loop run zero times and returns an empty array, which looks like a successful no-op.
- Suggestion: If `count < 0`, return `r_notint()` / Redis's out-of-range error before mutating.
- Status: open

### Issue 21 -- Severity: suggestion
- File: `lib/store_test.mko:56-84`, `lib/store_test.mko:120-127`, `lib/glob_test.mko`
- Description: Tests that would hide the bugs above:

  - `TestZset` uses `str_contains` for `ZRANGE` and would pass if `a`/`b` were reversed (the exact sort bug Issue 10 would produce for equal/NaN scores).
  - `TestMgetMset` uses `str_contains` for `"1"`, `"2"`, `"$-1"` and would pass if nils and values were in the wrong slots (Issue 4).
  - `TestList` only checks `LRANGE` starts with `*3\r\n`, not `b,a,c` order after `LPUSH a b` + `RPUSH c`.
  - `TestExpireTtl` only checks the TTL reply starts with `:`.
  - No tests for MULTI, SCAN, RENAME, MSETNX, KEEPTTL, AOF/SELECT, LPOP count 0, SET on a hash, `ZADD` `"abc"`, `SELECT foo`, or glob `*a*a*…`.

- Suggestion: Assert full RESP bytes (or decoded arrays) for MGET/LRANGE/ZRANGE. Add the cases listed above; they are the cheapest regression net for Issues 1–18.
- Status: open

### Issue 22 -- Severity: nit
- File: `lib/resp.mko:79-81`, `lib/store.mko:506`
- Description: `r_unknown` interpolates the client command name into a simple error string. A bulk command name containing `\r\n` splits the RESP stream (`-ERR unknown command 'foo\r\n+OK'\r\n`) and desynchronizes the client parser. Unlikely from `redis-cli`, trivial from a raw socket.
- Suggestion: Sanitize `\r`/`\n` in error payloads, or reply with a static unknown-command error.
- Status: open
