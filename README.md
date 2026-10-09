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

## Response cache

As in the Rust and C ports, authenticated room, messages, sidebar and search responses keep their completed identity or gzip representation for up to 15 seconds in a bounded 64 MiB store (`CAMPFIRE_RESPONSE_CACHE_MB`; `0` disables it). As in the C port, the database generation advances when the writer commits and whenever a reader connection sees its own `PRAGMA data_version` change, so any commit — including another process's writes — moves the cache to a new generation without a global lock. The generation is captured before authentication and checked again at lookup and admission, so a commit during authentication or rendering cannot serve or store an old page under the new generation. Session authentication and room membership still run on every request. Requests with flash, `Cache-Control: no-cache`/`no-store`, `Pragma: no-cache`, `Range` or `Upgrade` bypass the store. The key covers the user, session, URL, host and every request header, in the order sent, except validators and tracing headers. Set-Cookie headers are never stored: a hit adds its own `last_room` and session refresh cookies, and answers `If-None-Match` as the handler would.

Hits are answered on the connection's event loop by `CachedReadHandler`, which sits in the HTTP/1 pipeline before Hummingbird, as the C port's loops answer them: one pass over a free reader connection checks the generation, the session, room membership and the generation again, then writes the stored bytes with Hummingbird's `Date` and `Server` headers. Everything else reaches the router unchanged: misses, flash, sessions due an activity update, `Connection: close`, requests with a body, a busy reader pool, and every request on a connection with an earlier response still being produced, so responses keep request order.

## Performance

Swift leads the C and Rust ports on every benchmarked route in the shared [once-campfire-verification](https://github.com/pierophp/once-campfire-verification) harness, which validates every response against its route contract and audits every acknowledged write: medians from three alternating runs, 16 clients, four server CPUs, gzip (`--apps rust,swift,c --routes room_show,messages_page,sidebar,search,post_message`; [results](bench/results/verification-event-loop-20261009)):

| Endpoint | Swift | Swift `505baf6` | C `135fc20` | Rust `9872c1d` | Swift vs C |
|---|---:|---:|---:|---:|---:|
| Room page | 53,820 | 31,305 | 41,563 | 28,469 | 1.29× |
| Messages page | 55,291 | 32,456 | 43,709 | 27,366 | 1.26× |
| Sidebar | 62,474 | 33,737 | 46,667 | 31,547 | 1.34× |
| Search | 59,880 | 34,034 | 47,953 | 29,677 | 1.25× |
| Post message | 3,146 | 3,298 | 1,647 | 2,300 | 1.91× |

`505baf6` is the previous revision (response cache, router-served hits), measured in the same harness on the same day; C and Rust are from the run with this revision.

Read latency is also the lowest of the three: median p50 0.20–0.23 ms and p99 0.42–0.49 ms, against C's 0.31–0.36 / 0.68–0.83 ms and Rust's 0.48–0.56 / 1.03–1.11 ms. Posting p99 swings between about 10 and 40 ms from run to run in this and the previous revision alike (WAL checkpoints); its median is about 7% higher than before, now that handlers share the event-loop threads with I/O.

Previous revision's runs: [Rust, Swift and C](bench/results/verification-rust-swift-c-20261009), [Rust and Swift](bench/results/verification-rust-swift-20261009); before the response cache Swift read at 16–21k req/s ([local runner](bench/results/response-cache-20261009)). The Swift port does not serve stylesheet assets or the Rails `/up` page, so it is measured on these routes only. Search returns the newest 100 matches by message id, as that contract and the Rust port do.

What the profiles (`perf` inside the container) led to:

- **WAL checkpoints.** A WAL hook reports the log's size in pages after each commit, as in the Rust port. Every 1,000 pages wake the checkpointer for a PASSIVE checkpoint; at 10,000 the writer runs RESTART. The previous trigger read the WAL file's size, which never shrinks, so once the file passed 40 MB every commit ran a RESTART checkpoint that slept waiting for readers.
- **Async database waits.** `readAsync` runs on a free reader connection inline or suspends the task until a reader thread takes it; `writeAsync` suspends until the writer thread finishes. Waiting requests no longer hold cooperative threads, and each route does its reads in one hop instead of a `Task.detached` per query.
- **SQLite build.** The amalgamation is compiled with `-O3` (release C targets otherwise get `-Os`) and `SQLITE_DEFAULT_MEMSTATUS=0`, which drops a global mutex taken on every allocation. Connections open with `SQLITE_OPEN_NOMUTEX`, since each is used by one thread at a time.
- **Pages from parts.** `RenderBuffer` writes into `ByteBuffer`s and keeps cached message fragments by reference. A `RenderedPage` hashes its text and its fragments' ids (a tenth of a room page's bytes) into an identity that memoizes the ETag — still SHA-256 of the whole body, as `Rack::ETag` computes it — and keys the gzip cache. The body is joined only when sent uncompressed or first compressed.
- **Per-request Foundation work.** The secret and signers are created once, and signed avatar IDs and Turbo stream names are memoized. UTC dates are formatted and parsed arithmetically instead of through `DateFormatter`, `Calendar` and `ISO8601DateFormatter`. Cookie parsing, encoding negotiation and verified session cookies (expiry is still checked on every request) are memoized per header value, as is an empty flash. Action Text's regular expressions are compiled once.
- **Queries.** Message pages fetch the 40 newest and reverse them in Swift, as Rails' `last_page` does, and compute `data-message-timestamp` in Swift for Rails' timestamp shape (other shapes still use SQLite's expression). The sidebar computes room epochs in its main query instead of one query per room.
- **Response cache.** Repeated authenticated reads return the stored final (gzip) response after authentication and membership checks; see [Response cache](#response-cache). This is the Rust port's `d09811c` and doubles read throughput.
- **Event-loop execution.** Profiles showed 60% of CPU in Swift Concurrency's pool and 40% in the NIO loops, with two thread hand-offs per request. The NIO singleton group, sized to the allowed CPUs, is installed as the concurrency global executor (`CAMPFIRE_EVENT_LOOP_EXECUTOR=0` restores the default pool), and `CachedReadHandler` answers cache hits without the async channel bridge, a task, the router or the middleware. The C port's single-thread loop is the model.
- **Caches.** The fragment cache keys messages by id and version and evicts with CLOCK instead of scanning for the least recently used entry on every insert.

Differential tests check the arithmetic date parser and formatters against Foundation on tens of thousands of random values, and the timestamp computation against SQLite. The parser reproduces the formatter's floating-point path, which differs from integer arithmetic by 1µs far from 1970.

The [previous before/after benchmark](bench/results/key-cache-20261006/report.md) covers the PBKDF2 key cache and timestamp memoization in `32f31f8`, with its runner and parity checks.
