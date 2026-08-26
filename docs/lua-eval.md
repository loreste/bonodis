# Lua scripting

Bonodis supports `EVAL` with a sandboxed subset of Lua. Scripts run atomically on a single shard.

## Basic usage

```
EVAL "return 1 + 2" 0
# 3

EVAL "return redis.call('GET', KEYS[1])" 1 mykey
# (value of mykey)

EVAL "redis.call('SET', KEYS[1], ARGV[1]) return redis.call('GET', KEYS[1])" 1 mykey myvalue
# "myvalue"
```

The second argument is the number of keys. Keys go into `KEYS[1]`, `KEYS[2]`, etc. Remaining arguments go into `ARGV[1]`, `ARGV[2]`, etc.

## What's available

- `KEYS` and `ARGV` arrays
- `redis.call(cmd, ...)` -- run a Bonodis command, errors propagate
- `redis.pcall(cmd, ...)` -- run a Bonodis command, errors are caught
- Local variables and assignment
- `if` / `while` / `and` / `or`
- String literals and numbers
- `#` (length operator)
- `return`

## What's NOT available

- `os`, `io`, `load`, `require` -- blocked for security
- `cjson`, `cmsgpack` -- not implemented
- Tables, metatables -- not supported
- `for` loops -- use `while`
- `function` definitions -- inline only
- `pcall`/`xpcall` on arbitrary functions -- only `redis.pcall`

This is a sandbox, not a full Lua 5.1 VM.

## SCRIPT LOAD / EVALSHA

```
SCRIPT LOAD "return redis.call('GET', KEYS[1])"
# "a1b2c3..."  (SHA1 hash)

EVALSHA a1b2c3... 1 mykey
# (value of mykey)
```

Cached scripts persist in memory until `SCRIPT FLUSH`.

```
SCRIPT EXISTS a1b2c3...
# 1

SCRIPT FLUSH
```

## Same-slot requirement

All keys accessed by a script must hash to the same slot. If keys span multiple shards, use hash tags:

```
EVAL "redis.call('SET', KEYS[1], redis.call('GET', KEYS[2]))" 2 {x}dst {x}src
```

## Limits

- Script size: 64 KB max
- Nesting depth: 200 (prevents stack overflow from deeply nested parentheses)
- Scripts block the shard they run on. Keep them short.

## Examples

### Conditional set

```
EVAL "local v = redis.call('GET', KEYS[1]) if v then return v else redis.call('SET', KEYS[1], ARGV[1]) return ARGV[1] end" 1 mykey default
```

### Increment with ceiling

```
EVAL "local n = redis.call('INCR', KEYS[1]) if n > 100 then redis.call('SET', KEYS[1], '100') return 100 end return n" 1 counter
```

### Atomic swap

```
EVAL "local a = redis.call('GET', KEYS[1]) local b = redis.call('GET', KEYS[2]) redis.call('SET', KEYS[1], b) redis.call('SET', KEYS[2], a) return 'OK'" 2 {s}a {s}b
```
