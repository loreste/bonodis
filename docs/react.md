# REACT triggers

Server-side triggers that fire when a key (or glob pattern) is written, deleted, or expired. The reaction commands run on the same shard, same thread, with no network round-trips.

## Why

Without REACT, updating derived state requires the client to make multiple calls:

```
SET {x}src "hello"     # write the source
GET {x}src             # read it back
SET {x}copy "hello"    # write the derived key
```

Three round-trips. With REACT, you define the rule once and the server handles it:

```
REACT CREATE mycopy {x}src ON WRITE SET {x}copy $VALUE
SET {x}src "hello"
# {x}copy is already "hello" -- one round-trip
```

## Create a rule

```
REACT CREATE <name> <key_or_glob> ON <WRITE|DELETE|EXPIRE|ANY> <cmd> [arg ...] [| <cmd> [arg ...]]
```

- `name` -- unique identifier for the rule
- `key_or_glob` -- exact key or glob pattern (`*`, `?`, `[...]`, e.g. `user:*` or `{r}item:*`) that triggers the rule
- `ON <event>` -- event type:
  - `ON WRITE` -- fires when a key is created or modified (`SET`, `HSET`, `LPUSH`, `ZADD`, etc.)
  - `ON DELETE` -- fires when a key is explicitly removed (`DEL`, `UNLINK`, `GETDEL`, `HGETDEL`, `CAD`, `DELEX`)
  - `ON EXPIRE` -- fires when a key's TTL expires lazily or during periodic sweep
  - `ON ANY` -- fires on write, delete, or expire
- `|` (pipe) separates chained commands

```
REACT CREATE copier {r}src ON WRITE SET {r}dst $VALUE
REACT CREATE audit sess:* ON EXPIRE INCR stats:expired
REACT CREATE cleanup {u}user:* ON DELETE SREM {u}active_users $KEY
```

## Substitutions

| Variable | Replaced with |
| --- | --- |
| `$KEY` | The key that triggered the event |
| `$VALUE` | The value that was written (`argv[2]` of the write command) |
| `$RESULT` | The RESP reply of the previous piped command |

`$KEY` and `$VALUE` are substituted at collection time. `$RESULT` is substituted at execution time, after the previous command runs.

## Chaining with pipes

Pipe `|` separates commands. Each command runs in order. `$RESULT` carries the output forward.

```
REACT CREATE chain {c}src ON WRITE GET {c}src | SET {c}copy $RESULT
```

When `{c}src` is written:
1. `GET {c}src` runs, returns the value
2. `SET {c}copy <result>` runs, stores the value

The RESP reply is extracted automatically: bulk strings become their payload, integers become their string representation, simple strings become their text.

## Examples

### Copy a value

```
REACT CREATE cp {r}src ON WRITE SET {r}dst $VALUE
SET {r}src hello
GET {r}dst    # "hello"
```

### Track expired sessions with a glob trigger

```
REACT CREATE exp_audit sess:* ON EXPIRE INCR stats:expired
SET sess:42 "active" PX 100
# After 100ms, stats:expired is automatically incremented on the shard
```

### Increment a counter on every write

```
REACT CREATE counter {r}data ON WRITE INCR {r}writes
SET {r}data "first"
SET {r}data "second"
GET {r}writes    # "2"
```

### Agent context rebuild

```
REACT CREATE ctx {a}mem ON WRITE BRAIN COMPACT {a}mem | BRAIN PACK {a}sess {a}mem
BRAIN REMEMBER {a}mem p1 "user likes dark mode"
# compact + pack ran automatically
```

## List rules

```
REACT LIST
```

Returns pairs of `name, key_or_glob` for all rules on all shards.

## Delete a rule

```
REACT DELETE <name>
```

Returns `:1` if the rule existed, `:0` if it didn't.

After deletion, events on the key no longer trigger the rule.

## Constraints

**Same shard.** The trigger key and all keys in the reaction commands execute on the triggered key's shard. Use a shared hash tag (`{r}src` and `{r}dst`) so reaction commands target keys on the same shard.

**Exact keys and globs.** Both exact keys (`{r}src`) and glob patterns (`user:*`, `sess:?`, `[a-z]*`) are supported.

**No recursion.** If a reaction writes to a key that also has a REACT rule, the nested rule does not fire. This prevents infinite loops.

**Persisted.** Rules survive server restart. They are stored in the WAL as `REACT CREATE` commands and replayed on startup.

**Events.** REACT fires on `WRITE`, `DELETE`, `EXPIRE`, or `ANY`. Pure reads (`GET` on a non-expired key) do not trigger reactions.

## When not to use REACT

- When the derived state depends on keys from different shards without a shared `{tag}` (use application-level logic instead)
- When the reaction needs complex branching logic (use `EVAL` for that)
- When you need the reaction's result returned synchronously as the write command's reply (REACT runs immediately after the write reply is produced)
