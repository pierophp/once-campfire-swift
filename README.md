# once-campfire-swift

A Swift 6.4 / Hummingbird 2 server skeleton for the ONCE Campfire benchmark port. SQLite 3.53.4 is compiled from the vendored amalgamation with FTS5 and SQLite multi-thread mode.

## Build and test

```sh
swift build -c release
swift test
```

The HTTP black-box test uses a fresh copy of the Rust parity seed when available. Set `CAMPFIRE_SEED_DIR` to the seed directory if it is outside this checkout. The test skips with a message when the seed is missing; set `CAMPFIRE_REQUIRE_SEED=1` to make that a failure.

## Run

```sh
docker build -t campfire-swift .
docker run --rm \
  -e HTTP_PORT=80 \
  -v "$PWD/parity/.seed/default/db:/rails/storage/db" \
  -v "$PWD/parity/.seed/default/storage:/rails/storage/files" \
  -p 8080:80 campfire-swift
```

The image listens on plain HTTP at `HTTP_PORT` (default `80`), opens `/rails/storage/db/production.sqlite3`, and responds to `GET /up`. It does not select a container `USER`, so the benchmark harness can pass its host uid. The NIO event-loop group uses the process's allowed CPU list, then the cgroup cpuset, to size its threads.

## Response compression

The HTTP middleware negotiates `gzip` and `identity` using Rack::Deflater-compatible quality ordering, adds `Vary: Accept-Encoding`, and returns 406 when neither supported encoding is acceptable. It skips bodyless statuses, empty bodies, `Cache-Control: no-transform`, and already encoded responses. Gzip uses the system zlib implementation at level 6. Compressed bodies are cached within a 32 MiB byte budget (a single entry larger than 8 MiB is not cached), with CLOCK eviction. A page rendered from cached message fragments declares its identity to the middleware, so a cache hit never reads or joins the plain body; any other body is found by CRC-32 and length and confirmed by comparing its bytes. The `swift-identity` benchmark sends `Accept-Encoding: identity` to exercise the uncompressed response path.

## Performance

Swift now outperforms the Rust port in throughput on every benchmarked endpoint: medians from three runs, 16 clients, four server CPUs, gzip ([raw results](bench/results/wal-pages-20261006)):

| Endpoint | Swift | Rust `ccece30` | Swift vs Rust |
|---|---:|---:|---:|
| Room page | 16,720 | 14,575 | +15% (1.15×) |
| Messages page | 19,259 | 16,718 | +15% (1.15×) |
| Sidebar | 15,532 | 13,366 | +16% (1.16×) |
| Search | 15,781 | 13,613 | +16% (1.16×) |
| Post message | 3,197 | 3,050 | +5% (1.05×) |

Swift has the lower median latency everywhere but a higher p99 (2.4–3.2 ms against 1.6–2.2 ms on reads; 29.5 ms against 10.9 ms on posts, from WAL checkpoints on disk), and peaks at ~175 MiB against Rust's ~145 MiB. Read responses, including ETags, are byte-identical to the previous revision.

What the profiles (`perf` inside the container) led to:

- **WAL checkpoints.** A WAL hook reports the log's size in pages after each commit, as in the Rust port. Every 1,000 pages wake the checkpointer for a PASSIVE checkpoint; at 10,000 the writer runs RESTART. The previous trigger read the WAL file's size, which never shrinks, so once the file passed 40 MB every commit ran a RESTART checkpoint that slept waiting for readers.
- **Async database waits.** `readAsync` runs on a free reader connection inline or suspends the task until a reader thread takes it; `writeAsync` suspends until the writer thread finishes. Waiting requests no longer hold cooperative threads, and each route does its reads in one hop instead of a `Task.detached` per query.
- **SQLite build.** The amalgamation is compiled with `-O3` (release C targets otherwise get `-Os`) and `SQLITE_DEFAULT_MEMSTATUS=0`, which drops a global mutex taken on every allocation. Connections open with `SQLITE_OPEN_NOMUTEX`, since each is used by one thread at a time.
- **Pages from parts.** `RenderBuffer` writes into `ByteBuffer`s and keeps cached message fragments by reference. A `RenderedPage` hashes its text and its fragments' ids (a tenth of a room page's bytes) into an identity that memoizes the ETag — still SHA-256 of the whole body, as `Rack::ETag` computes it — and keys the gzip cache. The body is joined only when sent uncompressed or first compressed.
- **Per-request Foundation work.** The secret and signers are created once, and signed avatar IDs and Turbo stream names are memoized. UTC dates are formatted and parsed arithmetically instead of through `DateFormatter`, `Calendar` and `ISO8601DateFormatter`. Cookie parsing, encoding negotiation and verified session cookies (expiry is still checked on every request) are memoized per header value, as is an empty flash. Action Text's regular expressions are compiled once.
- **Queries.** Message pages fetch the 40 newest and reverse them in Swift, as Rails' `last_page` does, and compute `data-message-timestamp` in Swift for Rails' timestamp shape (other shapes still use SQLite's expression). The sidebar computes room epochs in its main query instead of one query per room.
- **Caches.** The fragment cache keys messages by id and version and evicts with CLOCK instead of scanning for the least recently used entry on every insert.

Differential tests check the arithmetic date parser and formatters against Foundation on tens of thousands of random values, and the timestamp computation against SQLite. The parser reproduces the formatter's floating-point path, which differs from integer arithmetic by 1µs far from 1970.

The [previous before/after benchmark](bench/results/key-cache-20261006/report.md) covers the PBKDF2 key cache and timestamp memoization in `32f31f8`, with its runner and parity checks.
