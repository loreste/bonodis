# TLS

Bonodis supports TLS on the RESP listener and on replica/cluster connections.

## Server-side TLS

```
bonodis --tls-cert cert.pem --tls-key key.pem --bind 127.0.0.1 --port 6379
```

All client connections are wrapped in TLS. The CLI:

```
bonodis-cli --tls PING
```

## Verified TLS (CA)

To verify peers (replicas, cluster nodes, clients):

```
bonodis --tls-cert cert.pem --tls-key key.pem --tls-ca ca.pem --bind 127.0.0.1
```

Without `--tls-ca`, self-signed certificates are accepted. With it, the peer must present a certificate signed by the CA.

CLI with CA verification:

```
bonodis-cli --tls --tls-ca ca.pem PING
```

## Replica TLS

The replica uses TLS to connect to the master if the master has TLS enabled:

```
# Master
bonodis --port 6379 --tls-cert cert.pem --tls-key key.pem

# Replica
bonodis --port 6380 --tls-cert cert.pem --tls-key key.pem --replica-of 127.0.0.1:6379
```

## Cluster TLS

Same flags. TLS wraps the same RESP port used for client traffic and gossip. There is no separate cluster bus port.

## Unix sockets

Unix sockets skip TLS even if `--tls-cert` is set. They are local by definition.

```
bonodis --tls-cert cert.pem --tls-key key.pem --unixsocket /tmp/bonodis.sock
bonodis-cli -s /tmp/bonodis.sock PING   # no TLS, direct local connection
bonodis-cli --tls PING                   # TLS over TCP
```
