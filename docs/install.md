# Installation

## Requirements

- [Mako](https://github.com/loreste/mako) 0.5.7 or later
- Linux (x86_64, arm64) or macOS (Apple Silicon, Intel)
- Windows is not supported (the server uses Unix syscalls for sockets and signals)

## Install Mako

### macOS

```
brew install loreste/tap/makori
```

### Linux

```
curl -fsSL https://raw.githubusercontent.com/loreste/mako/main/install.sh | sh
```

Or build from source:

```
git clone https://github.com/loreste/mako
cd mako && make install
```

Verify:

```
makori --version
```

## Get Bonodis

```
git clone https://github.com/loreste/bonodis
cd bonodis
```

### From a release tag

```
git clone --branch v0.14.0 https://github.com/loreste/bonodis
cd bonodis
```

## Run (development)

No build step needed. Mako compiles and runs in one command:

```
makori run -p lib -- --bind 127.0.0.1 --port 6379 --protected-mode no
```

In another terminal:

```
makori run -p cli -- PING
makori run -p cli -- SET hello world
makori run -p cli -- GET hello
```

## Run tests

```
makori test .
```

All 12 test suites should pass.

## Production

For production use, run the server with persistence and memory limits:

```
makori run -p lib -- --prod --bind 0.0.0.0 --port 6379 \
    --requirepass <password> \
    --appendonly yes --dir /var/lib/bonodis \
    --maxmemory 1073741824 \
    --protected-mode yes
```

`--prod` refuses to start without `--maxmemory` and `--appendonly yes`. A public bind also requires `--requirepass`.

## systemd (Linux)

```
sudo mkdir -p /var/lib/bonodis
sudo useradd -r -s /usr/sbin/nologin bonodis
sudo chown bonodis:bonodis /var/lib/bonodis
sudo cp deploy/bonodis.service /etc/systemd/system/
```

Edit `/etc/systemd/system/bonodis.service` and set your password, memory limit, and data directory. Then:

```
sudo systemctl enable --now bonodis
sudo systemctl status bonodis
```

## Docker

```
docker build -t bonodis .
docker run --name bonodis -p 6379:6379 -v bonodis-data:/data bonodis
```

The Dockerfile expects a `bonodis` binary in the repo root. Build it first with `makori run -p lib` on a Linux host, or use a multi-stage build.

## Connecting

Any Redis client works. Bonodis speaks RESP2 on the same default port (6379).

```python
# Python
import redis
r = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)
r.set("k", "v")
r.get("k")
```

```javascript
// Node.js
const Redis = require("ioredis");
const r = new Redis(6379, "127.0.0.1");
await r.set("k", "v");
await r.get("k");
```

```go
// Go
rdb := redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379"})
rdb.Set(ctx, "k", "v", 0)
rdb.Get(ctx, "k")
```

```
# CLI
bonodis-cli -h 127.0.0.1 -p 6379 PING
# or via makori
makori run -p cli -- -h 127.0.0.1 -p 6379 PING
```

## Platform notes

### macOS

Works on both Apple Silicon (arm64) and Intel (x86_64). No extra dependencies beyond Mako.

### Linux

Works on x86_64 and arm64. For production, set `ulimit -n` above `--maxclients` (default 50000). If using systemd, set `LimitNOFILE` in the unit file.

### Windows

Not supported. Bonodis uses Unix domain sockets, `SO_REUSEPORT`, `uname`, `signal`, and other POSIX APIs that do not exist on Windows. WSL2 with a Linux distribution works.

## Uninstall

Remove the cloned directory. Bonodis has no global state outside its `--dir` data directory.
