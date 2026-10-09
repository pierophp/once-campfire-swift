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

As in the Rust and C ports, authenticated room, messages, sidebar and search responses keep their completed identity or gzip representation for up to 15 seconds in a bounded 64 MiB store (`CAMPFIRE_RESPONSE_CACHE_MB`; `0` disables it). A dedicated read-only SQLite connection watches `PRAGMA data_version`, so any commit — including another process's writes — moves the cache to a new generation. The generation is captured before authentication and checked again at lookup and admission, so a commit during authentication or rendering cannot store an old page under the new generation. Session authentication and room membership still run on every request. Requests with flash, `Cache-Control: no-cache`/`no-store`, `Pragma: no-cache`, `Range` or `Upgrade` bypass the store. The key covers the user, session, URL, host and every request header except validators and tracing headers. Set-Cookie headers are never stored: a hit adds its own `last_room` and session refresh cookies, and answers `If-None-Match` as the handler would.

## Performance

Swift outperforms the Rust port in throughput on every benchmarked endpoint: medians from three runs, 16 clients, four server CPUs, gzip, Rust at `9872c1d` with its response cache ([raw results](bench/results/response-cache-20261009)):

| Endpoint | Swift before response cache | Swift | Rust `9872c1d` | Swift vs Rust |
|---|---:|---:|---:|---:|
| Room page | 16,909 | 33,176 | 30,277 | +10% (1.10×) |
| Messages page | 20,622 | 33,756 | 28,559 | +18% (1.18×) |
| Sidebar | 16,106 | 36,392 | 32,847 | +11% (1.11×) |
| Search | 15,732 | 35,950 | 32,151 | +12% (1.12×) |
| Post message | 3,420 | 3,394 | 2,287 | +48% (1.48×) |

Median p99 latency, Swift / Rust: room 1.00 / 1.01 ms, messages 1.15 / 1.06, sidebar 1.12 / 0.99, search 1.16 / 1.02, post 9.70 / 12.94. Peak memory is 178–183 MiB against Rust's 140–177 MiB, unchanged from before the response cache.

The shared [once-campfire-verification](https://github.com/pierophp/once-campfire-verification) harness, which validates every response against its route contract and audits every acknowledged write, gives the same picture (`--apps rust,swift --routes room_show,messages_page,sidebar,search,post_message`): Swift / Rust medians of 32,685 / 29,375 (room), 33,042 / 28,134 (messages), 35,413 / 31,311 (sidebar), 35,221 / 31,146 (search) and 3,308 / 2,331 (post) req/s. Search returns the newest 100 matches by message id, as that contract and the Rust port do. The Swift port does not serve stylesheet assets or the Rails `/up` page, so it is measured on these routes only.

In a later three-way run of the same harness on a busier host (load average 5–8), the C port leads every read route by 1.33–1.44× over Swift (45,114 / 31,305 room, 46,732 / 32,456 messages, 46,274 / 33,737 sidebar, 45,103 / 34,034 search req/s, with p99 under 0.9 ms), while Swift posts twice as fast (3,298 against C's 1,657 and Rust's 1,962). Results: [Rust and Swift](bench/results/verification-rust-swift-20261009), [Rust, Swift and C](bench/results/verification-rust-swift-c-20261009).

What the profiles (`perf` inside the container) led to:

- **WAL checkpoints.** A WAL hook reports the log's size in pages after each commit, as in the Rust port. Every 1,000 pages wake the checkpointer for a PASSIVE checkpoint; at 10,000 the writer runs RESTART. The previous trigger read the WAL file's size, which never shrinks, so once the file passed 40 MB every commit ran a RESTART checkpoint that slept waiting for readers.
- **Async database waits.** `readAsync` runs on a free reader connection inline or suspends the task until a reader thread takes it; `writeAsync` suspends until the writer thread finishes. Waiting requests no longer hold cooperative threads, and each route does its reads in one hop instead of a `Task.detached` per query.
- **SQLite build.** The amalgamation is compiled with `-O3` (release C targets otherwise get `-Os`) and `SQLITE_DEFAULT_MEMSTATUS=0`, which drops a global mutex taken on every allocation. Connections open with `SQLITE_OPEN_NOMUTEX`, since each is used by one thread at a time.
- **Pages from parts.** `RenderBuffer` writes into `ByteBuffer`s and keeps cached message fragments by reference. A `RenderedPage` hashes its text and its fragments' ids (a tenth of a room page's bytes) into an identity that memoizes the ETag — still SHA-256 of the whole body, as `Rack::ETag` computes it — and keys the gzip cache. The body is joined only when sent uncompressed or first compressed.
- **Per-request Foundation work.** The secret and signers are created once, and signed avatar IDs and Turbo stream names are memoized. UTC dates are formatted and parsed arithmetically instead of through `DateFormatter`, `Calendar` and `ISO8601DateFormatter`. Cookie parsing, encoding negotiation and verified session cookies (expiry is still checked on every request) are memoized per header value, as is an empty flash. Action Text's regular expressions are compiled once.
- **Queries.** Message pages fetch the 40 newest and reverse them in Swift, as Rails' `last_page` does, and compute `data-message-timestamp` in Swift for Rails' timestamp shape (other shapes still use SQLite's expression). The sidebar computes room epochs in its main query instead of one query per room.
- **Response cache.** Repeated authenticated reads return the stored final (gzip) response after authentication and membership checks; see [Response cache](#response-cache). This is the Rust port's `d09811c` and doubles read throughput.
- **Caches.** The fragment cache keys messages by id and version and evicts with CLOCK instead of scanning for the least recently used entry on every insert.

Differential tests check the arithmetic date parser and formatters against Foundation on tens of thousands of random values, and the timestamp computation against SQLite. The parser reproduces the formatter's floating-point path, which differs from integer arithmetic by 1µs far from 1970.

The [previous before/after benchmark](bench/results/key-cache-20261006/report.md) covers the PBKDF2 key cache and timestamp memoization in `32f31f8`, with its runner and parity checks.
