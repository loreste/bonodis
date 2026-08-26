# REACT triggers

Server-side triggers that fire when a key is written. The reaction commands run on the same shard, same thread, with no network round-trips.

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
REACT CREATE <name> <key> ON WRITE <cmd> [arg ...] [| <cmd> [arg ...]]
```

- `name` -- unique identifier for the rule
- `key` -- exact key that triggers the rule when written
- Commands after `ON WRITE` run when the key is written successfully
- `|` (pipe) separates chained commands

```
REACT CREATE copier {r}src ON WRITE SET {r}dst $VALUE
```

## Substitutions

| Variable | Replaced with |
| --- | --- |
| `$KEY` | The key that was written |
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

Returns pairs of `name, key` for all rules on all shards.

## Delete a rule

```
REACT DELETE <name>
```

Returns `:1` if the rule existed, `:0` if it didn't.

After deletion, writes to the key no longer trigger anything.

## Constraints

**Same shard.** The trigger key and all keys in the reaction commands must share a hash tag. `{r}src` and `{r}dst` share the tag `r` and land on the same shard. `src` and `dst` without tags may land on different shards -- the reaction would run on `src`'s shard and the `SET dst` would only affect that shard's local store.

**Exact match.** The trigger key is matched exactly, not by glob pattern.

**No recursion.** If a reaction writes to a key that also has a REACT rule, the nested rule does not fire. This prevents infinite loops.

**Persisted.** Rules survive server restart. They are stored in the WAL as `REACT CREATE` commands and replayed on startup.

**One direction.** REACT fires on writes only. Reads do not trigger reactions.

## When not to use REACT

- When the derived state depends on keys from different shards (use application-level logic instead)
- When the reaction needs conditional logic (use `EVAL` for that)
- When you need the reaction's result returned to the client (REACT runs after the write reply is sent)
