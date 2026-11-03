# Lua scripting

Bonodis supports `EVAL`, `EVALSHA`, `EVAL_RO`, and `EVALSHA_RO` with a sandboxed subset of Lua and a built-in standard library (`string.*`, `math.*`, `cjson.*`, `redis.*`). Scripts run atomically on a single shard.

## Basic usage

```
EVAL "return 1 + 2" 0
# 3

EVAL "return redis.call('GET', KEYS[1])" 1 mykey
# (value of mykey)

EVAL "redis.call('SET', KEYS[1], ARGV[1]); return redis.call('GET', KEYS[1])" 1 mykey myvalue
# "myvalue"
```

The second argument is the number of keys. Keys go into `KEYS[1]`, `KEYS[2]`, etc. Remaining arguments go into `ARGV[1]`, `ARGV[2]`, etc. Statements can be separated by whitespace/newlines or `;`.

## Read-only scripts (`EVAL_RO` / `EVALSHA_RO`)

`EVAL_RO` and `EVALSHA_RO` execute scripts in strict read-only mode. Any attempt to invoke a write command via `redis.call` or `redis.pcall` is rejected with `-ERR Write commands are not allowed from read-only scripts`:

```
EVAL_RO "return redis.call('GET', KEYS[1])" 1 mykey
# (value of mykey)

EVAL_RO "return redis.call('SET', KEYS[1], 'x')" 1 mykey
# -ERR Write commands are not allowed from read-only scripts.
```

## What's available

- `KEYS` and `ARGV` arrays (1-indexed, `#KEYS` / `#ARGV` supported)
- **Redis bridge (`redis.*`)**:
  - `redis.call(cmd, ...)` -- run a Bonodis command; errors propagate
  - `redis.pcall(cmd, ...)` -- run a Bonodis command; errors are caught
  - `redis.status_reply(msg)` -- return a `+msg\r\n` simple string status reply
  - `redis.error_reply(msg)` -- return a `-ERR msg\r\n` error reply
  - `redis.sha1hex(str)` -- compute the 40-char lowercase hex SHA-1 digest of `str`
- **String library (`string.*`)**:
  - `string.len(s)` -- byte length of `s`
  - `string.sub(s, i [, j])` -- 1-indexed Lua substring (supports negative indices)
  - `string.lower(s)` / `string.upper(s)` -- ASCII case conversion
  - `string.find(s, pattern)` -- 1-indexed start index of substring `pattern` (or `nil`)
  - `string.rep(s, n)` -- repeat string `s` `n` times (capped at 4096)
- **Math library (`math.*`)**:
  - `math.min(a, b, ...)` / `math.max(a, b, ...)`
  - `math.abs(x)` / `math.floor(x)`
- **JSON library (`cjson.*`)**:
  - `cjson.decode(json_str)` -- parse a JSON object or value; fields can be accessed via `obj.field` or `obj["field"]` (including nested paths)
  - `cjson.encode(val)` -- serialize a value or decoded JSON object back to a JSON string
- **Type conversions & operators**:
  - `tostring(v)` / `tonumber(v)`
  - `#` (length operator), `..` (string concatenation), `+`, `-`, `*`, `/`, `%`, `==`, `~=`, `<`, `<=`, `>`, `>=`
  - Local variables (`local x = ...`), assignment, `if` / `else` / `end`, `while ... do ... end`, `and` / `or` / `not`, `return`

## What's NOT available

- `os`, `io`, `load`, `require` -- blocked for security
- `cmsgpack` -- not implemented
- General mutable Lua tables / metatables -- use `cjson.decode` for JSON objects
- `for` loops -- use `while`
- `function` definitions -- inline scripts only
- `pcall`/`xpcall` on arbitrary functions -- only `redis.pcall`

This is a deterministic sandbox, not a full Lua 5.1 VM.

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
- Loop steps: 10,000 iterations max per block/loop
- Scripts block the shard they run on. Keep them short.

## Examples

### Inspect and mutate JSON in Lua (`cjson.decode`)

```
EVAL "local obj = cjson.decode(ARGV[1]); return obj.user .. ':' .. tostring(obj.lvl)" 0 '{"user":"ada","lvl":9}'
# "ada:9"
```

### String & math helpers

```
EVAL "return string.upper(string.sub('bonodis', 1, 4))" 0
# "BONO"

EVAL "return math.max(10, 42, 7) + math.abs(-8)" 0
# 50
```

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
EVAL "local a = redis.call('GET', KEYS[1]) local b = redis.call('GET', KEYS[2]) redis.call('SET', KEYS[1], b) redis.call('SET', KEYS[2], a) return redis.status_reply('OK')" 2 {s}a {s}b
```
