# Persistence

By default Bonodis keeps everything in memory. If the process stops, data is gone. This page covers how to make data survive restarts.

## WAL (append-only file)

```
bonodis --appendonly yes --dir ./data
```

Every successful write is appended to `./data/appendonly.aof` as a RESP command prefixed with the database number. On restart, the file is replayed and the store is rebuilt.

### Fsync policy

`--appendfsync` controls when the WAL is flushed to disk:

| Value | Behavior | Tradeoff |
| --- | --- | --- |
| `everysec` (default) | Fsync once per second | Up to 1 second of writes lost on crash |
| `always` | Fsync after every write | Slowest, no data loss |
| `no` | Never fsync (OS decides) | Fastest, most data at risk |

### WAL compaction

The WAL grows without bound. To compact it:

```
bonodis-cli BGREWRITEAOF
```

This rebuilds the WAL from the current in-memory state. The old file is replaced atomically.

## Snapshots

```
bonodis-cli SAVE
```

Writes `<dir>/dump.bonodis` -- a command stream (not Redis RDB format). No fork. The process blocks while writing. Use `BGSAVE` if you don't want to block (currently same behavior -- no fork either way).

`LASTSAVE` returns the Unix timestamp of the last successful save.

## What gets persisted

- All data commands (SET, HSET, LPUSH, SADD, ZADD, XADD, etc.)
- REACT CREATE / REACT DELETE rules
- Database number (SELECT is recorded per write)

What is NOT persisted:
- Client connections, subscriptions, MONITOR state
- Slowlog entries
- Runtime CONFIG SET changes (use CONFIG REWRITE to save config)

## Database isolation

Each WAL record includes the database number. `SELECT 3; SET k v` writes db 3 before the SET in the WAL. On replay, the key is restored to db 3.

## CONFIG REWRITE

Writes current config to `<dir>/bonodis.conf`:

```
bonodis-cli CONFIG REWRITE
```

This saves port, maxmemory, appendfsync, and timeout. It does not save the password (use `--requirepass` or an env variable).

## Production

Use `--prod` to enforce persistence:

```
bonodis --prod --appendonly yes --maxmemory 1073741824 --dir /var/lib/bonodis
```

`--prod` refuses to start if `--appendonly` is not `yes` or `--maxmemory` is not set.
