# RedisRuby

A from-scratch reimplementation of the [Redis](https://redis.io) server in
**Ruby**, typed end-to-end with [Sorbet](https://sorbet.org). It speaks the real
RESP2/RESP3 wire protocol, so `redis-cli` and standard client libraries connect
and work unmodified.

```console
$ bundle install
$ bundle exec bin/redis-server-rb --port 6379
$ redis-cli -p 6379 ping
PONG
```

## What's implemented

- **Wire protocol** — RESP2 and RESP3, negotiated via `HELLO`. Streaming,
  binary-safe request parser supporting both the multibulk and inline
  (telnet) protocols, with full RESP3 type support (maps, sets, doubles,
  booleans, big numbers, verbatim strings, push frames).
- **Event loop** — a single-threaded `IO.select` reactor, faithful to Redis'
  own design. Command execution is serialized through one loop, which is what
  makes the atomicity guarantees hold without locking.
- **Data types & ~165 commands**
  - Strings: `GET`/`SET` (with `EX`/`PX`/`EXAT`/`PXAT`/`NX`/`XX`/`KEEPTTL`/`GET`),
    `INCR`/`DECR`/`INCRBYFLOAT`, `APPEND`, `GETRANGE`/`SETRANGE`, `MGET`/`MSET`, …
  - Bitmaps: `SETBIT`, `GETBIT`, `BITCOUNT`, `BITPOS`, `BITOP`.
  - Lists: `LPUSH`/`RPUSH`, `LPOP`/`RPOP`, `LRANGE`, `LINSERT`, `LREM`, `LMOVE`,
    `LPOS`, `LMPOP`, …
  - Hashes: `HSET`, `HGETALL`, `HINCRBY`/`HINCRBYFLOAT`, `HRANDFIELD`, `HSCAN`, …
  - Sets: `SADD`, `SMEMBERS`, `SINTER`/`SUNION`/`SDIFF` (+`STORE`),
    `SINTERCARD`, `SSCAN`, …
  - Sorted sets: `ZADD` (full option matrix), the `BYSCORE`/`BYLEX`/`REV`
    range family, `ZRANGESTORE`, `ZUNION`/`ZINTER`/`ZDIFF` (+`STORE`, with
    `WEIGHTS`/`AGGREGATE`), `ZPOPMIN`/`ZPOPMAX`, `ZMPOP`, `ZSCAN`, …
  - Generic keyspace: `DEL`, `EXPIRE`/`TTL` family (with `NX`/`XX`/`GT`/`LT`),
    `TYPE`, `KEYS`, `SCAN`, `RENAME`, `COPY`, `MOVE`, `OBJECT ENCODING`, …
- **Keyspace** — 16 logical databases (`SELECT`/`SWAPDB`/`MOVE`), lazy and
  active key expiration.
- **Transactions** — `MULTI`/`EXEC`/`DISCARD` with `WATCH`/`UNWATCH`
  optimistic locking.
- **Pub/Sub** — channel, pattern (`PSUBSCRIBE`) and sharded (`SSUBSCRIBE`)
  subscriptions, plus `PUBSUB` introspection.
- **Persistence** — RDB-style point-in-time snapshots: `SAVE`, forked
  `BGSAVE`, automatic save points, snapshot load on startup, and
  `DEBUG RELOAD`.
- **Introspection** — `INFO`, `CONFIG GET`/`SET`, `CLIENT`, `COMMAND`,
  `DBSIZE`, `DEBUG`, `TIME`, …

## Architecture

```
lib/redis_ruby/
  protocol.rb        RESP2/RESP3 encoder + streaming request reader
  reply.rb           reply wrapper types (Double, Map, Set, Push, …)
  server.rb          event loop, dispatch, persistence orchestration, INFO
  client.rb          per-connection state
  database.rb        keyspace, expiration, WATCH bookkeeping
  pubsub.rb          publish/subscribe registry
  config.rb          CONFIG-backed settings
  types/             List / Hash / Set / SortedSet value classes
  commands/          one module per command family
  persistence/rdb.rb RDB-style snapshot serializer
```

Command handlers return plain Ruby values (`nil`, `Integer`, `String`,
`Array`) for the common cases and a `Reply::*` wrapper when a specific RESP3
type is required; the protocol layer downgrades RESP3-only types for RESP2
clients automatically.

## Development

```console
$ bundle exec rake test        # run the test suite
$ bundle exec rake typecheck   # run `srb tc`
```

The whole library type-checks clean under Sorbet (`# typed: strict` across
`lib/`) and ships a focused but thorough test suite that boots real servers
on ephemeral ports and drives them over TCP.

## Out of scope (for now)

"All of Redis" is ~200k lines of C. This project targets a deep, correct core
rather than every subsystem. Not (yet) implemented: replication, Redis
Cluster, AOF, Lua/Functions scripting, ACLs, Streams, HyperLogLog, Geo
commands, modules, TLS, and keyspace notifications. The command table and
type system are structured so these slot in cleanly.
