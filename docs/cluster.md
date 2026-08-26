# Cluster setup

How to run Bonodis across multiple nodes with automatic slot distribution and failover.

## Single node vs cluster

A single Bonodis process has 16 internal shards. For most workloads, one process is enough. Use cluster mode when:

- You need more memory than one machine has
- You need redundancy (replicas that can promote if a master dies)
- You want to distribute load across machines

## Three-node cluster

Start three instances, each with its own data directory:

```
bonodis --port 7000 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b0
bonodis --port 7001 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b1
bonodis --port 7002 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b2
```

Form the cluster:

```
bonodis-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002
```

This divides the 16384 slots across the three nodes. Each node owns roughly 5461 slots.

## Verify

```
bonodis-cli -p 7000 CLUSTER INFO
bonodis-cli -p 7000 CLUSTER NODES
bonodis-cli -p 7000 CLUSTER SLOTS
```

## Add a replica

Start a fourth node:

```
bonodis --port 7003 --bind 127.0.0.1 --protected-mode no --cluster-enabled yes --dir /tmp/b3
```

Attach it as a replica of the first master:

```
bonodis-cli --cluster add-node 127.0.0.1:7003 127.0.0.1:7000 --slave
```

The replica receives a full resync (stream of write commands, not an RDB dump) and then follows the master's write feed.

## Six nodes with replicas

One replica per master, created in one command:

```
bonodis-cli --cluster create --replicas 1 \
    127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 \
    127.0.0.1:7003 127.0.0.1:7004 127.0.0.1:7005
```

The first three become masters, the last three become replicas.

## Slot routing

```
slot = crc16(hashtag(key)) & 16383
```

Keys with a `{tag}` use only the tag for hashing: `{user}.profile` and `{user}.posts` land on the same node. If a client sends a command to the wrong node, it gets:

```
-MOVED 12345 127.0.0.1:7001
```

Most Redis client libraries handle `-MOVED` automatically and redirect.

## Auto-failover

Enabled by default in cluster mode (`--auto-failover yes`).

When a replica detects its master is down (after ~3 seconds of failed pings), the replica with the lowest node id starts an election. It asks the other replicas of the same master for votes. Promotion needs a majority (`n/2+1`, self counts).

- Two replicas: both must vote (one failure blocks failover)
- Three replicas: any two can promote (survives one replica loss)

Manual failover (from a replica):

```
bonodis-cli -p 7003 CLUSTER FAILOVER
```

This force-promotes without an election.

## Standalone replication (no cluster)

If you just want a read replica without cluster mode:

```
bonodis --port 6380 --bind 127.0.0.1 --protected-mode no --replica-of 127.0.0.1:6379
```

The replica streams writes from the master. `REPLICAOF NO ONE` promotes it back to master.

## Production notes

- Use `--prod` on every node to enforce memory limits and AOF
- Set `--requirepass` and `--protected-mode yes` for non-loopback binds
- `--cluster-announce-ip` tells other nodes how to reach this one (important for Docker/NAT)
- Topology is stored in `<dir>/nodes.conf`
- `CLUSTER SAVECONFIG` writes the current topology to disk
- Raise `ulimit -n` above `--maxclients` on every node

## Sentinel compatibility

Bonodis answers `SENTINEL GET-MASTER-ADDR-BY-NAME`, `MASTERS`, and `CKQUORUM` from the data process. There is no separate Sentinel process. Clients that use `sentinel://` connection strings can connect directly.
