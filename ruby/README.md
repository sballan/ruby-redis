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
- **Data types & ~207 commands**
  - Strings: `GET`/`SET` (with `EX`/`PX`/`EXAT`/`PXAT`/`NX`/`XX`/`KEEPTTL`/`GET`),
    `INCR`/`DECR`/`INCRBYFLOAT`, `APPEND`, `GETRANGE`/`SETRANGE`, `MGET`/`MSET`,
    `LCS` (with `LEN`/`IDX`/`MINMATCHLEN`/`WITHMATCHLEN`), …
  - Bitmaps: `SETBIT`, `GETBIT`, `BITCOUNT`, `BITPOS`, `BITOP`,
    `BITFIELD`/`BITFIELD_RO`.
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
  - Streams: `XADD` (with `*`/`ms-*`, `NOMKSTREAM`, `MAXLEN`/`MINID` trimming),
    `XLEN`, `XRANGE`/`XREVRANGE`, `XREAD` (+`BLOCK`), `XDEL`, `XTRIM`, `XSETID`,
    `XINFO`, and full consumer groups (`XGROUP`, `XREADGROUP`, `XACK`,
    `XPENDING`, `XCLAIM`, `XAUTOCLAIM`).
  - HyperLogLog: `PFADD`/`PFCOUNT`/`PFMERGE` (dense encoding, Ertl estimator).
  - Geo: `GEOADD`/`GEOPOS`/`GEODIST`/`GEOHASH`/`GEOSEARCH`/`GEOSEARCHSTORE`
    and the legacy `GEORADIUS`(`BYMEMBER`)(`_RO`) family, layered on the
    sorted set with 52-bit interleaved geohash scores.
- **Keyspace** — 16 logical databases (`SELECT`/`SWAPDB`/`MOVE`), lazy and
  active key expiration. `OBJECT ENCODING` reflects the real
  intset/listpack/quicklist/hashtable/skiplist transitions against the
  configured thresholds.
- **Transactions** — `MULTI`/`EXEC`/`DISCARD` with `WATCH`/`UNWATCH`
  optimistic locking.
- **Blocking** — `BLPOP`/`BRPOP`/`BLMOVE`/`BRPOPLPUSH`/`BLMPOP`/`BZPOPMIN`/
  `BZPOPMAX`/`BZMPOP` and `WAIT`. Clients park on their keys with optional
  timeouts wired into the reactor; pushes wake the longest-waiting client
  first (FIFO), and the commands run non-blocking inside `MULTI`/`EXEC`.
- **Pub/Sub** — channel, pattern (`PSUBSCRIBE`) and sharded (`SSUBSCRIBE`)
  subscriptions, plus `PUBSUB` introspection.
- **Keyspace notifications** — `notify-keyspace-events` with the
  `__keyspace@<db>__` / `__keyevent@<db>__` channels and per-class flag
  filtering (`K`/`E`/`A`/`g$lshzxt`), including `expired` events.
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
  types/             List / Hash / Set / SortedSet / Stream value classes
  commands/          one module per command family
                     (strings, lists, hashes, sets, sorted_sets, bitmaps,
                      streams, hyperloglog, geo, keys, blocking, …)
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

## Vision: the complete RedisRuby

The north star is **full functional parity with a modern Redis (7.x+) server** —
drop-in compatible enough that real applications, the official `redis-cli`, the
common client libraries, and ideally Redis' own integration test suite all run
against it unmodified — while remaining **idiomatic, exhaustively Sorbet-typed
Ruby that reads as a teaching-quality reference implementation** of how Redis
works.

"All of Redis" is ~200k lines of C. The strategy is to get each subsystem
*correct and well-typed* before moving outward, so the codebase stays a clear
model of the real thing rather than a pile of special cases.

### Guiding principles

- **Protocol- and behavior-compatible**, not source-compatible. We match Redis'
  observable semantics (replies, error strings, edge cases) rather than its C
  data structures.
- **Types are the spec.** Sorbet signatures document and enforce the shape of
  every command. Stringly-typed knobs become real types (see the engineering
  bar below).
- **Faithful to the single-threaded model.** The reactor stays the source of
  atomicity; new subsystems (blocking, replication, scripting) plug into it
  rather than around it.
- **Every feature ships with tests** that drive a real server over TCP.

### Roadmap

**Milestone 1 — Core data plane** ✅ *(shipped)*
RESP2/RESP3, the event loop, the five core types, keyspace + expiration,
transactions, pub/sub, and RDB-style snapshots.

**Milestone 2 — Complete the command surface**
- [x] Blocking commands: `BLPOP`/`BRPOP`/`BLMOVE`/`BRPOPLPUSH`/`BLMPOP`/`BZMPOP`/
      `BZPOPMIN`/`BZPOPMAX`, `WAIT`, with client parking + timeouts wired into
      the reactor
- [x] Streams: `XADD`/`XREAD`(+`BLOCK`)/`XRANGE`/`XREVRANGE`/`XDEL`/`XTRIM`/
      `XSETID`, consumer groups (`XGROUP`/`XREADGROUP`/`XACK`/`XPENDING`/
      `XCLAIM`/`XAUTOCLAIM`), `XINFO`
- [x] HyperLogLog: `PFADD`/`PFCOUNT`/`PFMERGE` (dense encoding + Ertl
      estimator; the sparse encoding is not modeled)
- [x] Geo: `GEOADD`/`GEOSEARCH`/`GEOSEARCHSTORE`/`GEODIST`/`GEOPOS`/`GEOHASH`
      and the legacy `GEORADIUS`(`BYMEMBER`)(`_RO`) family
- [x] Bitfields: `BITFIELD`/`BITFIELD_RO`, plus `LCS`
- [x] True `OBJECT ENCODING` fidelity (intset/listpack/quicklist/hashtable/
      skiplist transitions). *(Computed from contents on demand rather than
      latched; a rehash-safe `SCAN` cursor is still pending.)*

**Milestone 3 — Programmability**
- [ ] Lua scripting: `EVAL`/`EVALSHA`/`SCRIPT`, a sandboxed `redis.call`
- [ ] Functions: `FUNCTION LOAD`/`FCALL` libraries
- [x] Keyspace notifications (`notify-keyspace-events`) — keyspace/keyevent
      channels with class filtering, covering the common write commands and
      `expired` events
      *(per-key events for `RENAME`/`*MOVE` and the secondary empty-collection
      `del` are not yet emitted)*
- [ ] Client-side caching: `CLIENT TRACKING` + RESP3 invalidation pushes

**Milestone 4 — Durability**
- [ ] Byte-compatible RDB so real `.rdb` files load/save across versions (CRC64,
      the actual length/encoding opcodes)
- [ ] AOF with rewrite, fsync policies, and mixed RDB+AOF startup

**Milestone 5 — Replication & high availability**
- [ ] Master/replica: `REPLICAOF`, `PSYNC`, partial resync + replication backlog
- [ ] Sentinel: monitoring and automatic failover

**Milestone 6 — Horizontal scale**
- [ ] Redis Cluster: 16384 hash slots, `MOVED`/`ASK` redirects, the `CLUSTER`
      command family, resharding, and gossip

**Milestone 7 — Security & multi-tenancy**
- [ ] ACLs: users, rules, command/key categories, selectors
- [ ] TLS transport

**Milestone 8 — Observability & ops**
- [ ] Full `INFO` sections, `SLOWLOG`, `LATENCY`, `MONITOR`,
      `COMMAND DOCS`/`GETKEYS`, real memory accounting

### Engineering bar (cross-cutting)

- [ ] **Replace stringly-typed constants with Sorbet `T::Enum`s** — command
      flags, value types, `OBJECT ENCODING` names, RESP type tags, reply kinds,
      and option tokens (`NX`/`XX`/`GT`/`LT`, `BYSCORE`/`BYLEX`, aggregate modes)
      are currently symbols/strings; modeling them as enums makes the command
      table exhaustively checked and kills a class of typo bugs.
- [ ] `# typed: strict` everywhere, including the test suite (with RBIs), and no
      `T.untyped` in handler return positions where a `Reply` union will do.
- [ ] **Conformance**: run against Redis' upstream `tests/` integration suite and
      a matrix of real client libraries.
- [ ] **Performance**: a `redis-benchmark` harness, pipelining throughput
      targets, and an epoll/io_uring reactor backend behind the current
      `IO.select` one.
- [ ] **Robustness**: fuzz the RESP parser and property-test the data-structure
      invariants (sorted-set ordering, expiration, encoding transitions).
- [ ] A **module API** analog so extensions can register commands and types.

### Status today

Milestones 1 and 2 are complete: alongside the core data plane and the
blocking subsystem, the full Milestone 2 command surface has landed — streams
(with consumer groups), HyperLogLog, geo, bitfields, `LCS`, and real
`OBJECT ENCODING` fidelity — plus keyspace notifications from Milestone 3. That
brings the total to ~207 commands, still with clean `srb tc` and a green test
suite (driving real servers over TCP). Everything past it is deliberately
staged — the command table, reply system, and reactor are structured so each
milestone slots in without reworking the core.

The larger remaining subsystems are scripting (`EVAL`/`FUNCTION`, which need a
sandboxed Lua runtime), byte-compatible RDB and AOF, replication and Sentinel,
Redis Cluster, ACLs, and TLS — each a substantial body of work tracked in the
milestones above.

