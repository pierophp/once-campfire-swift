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

The HTTP middleware negotiates `gzip` and `identity` using Rack::Deflater-compatible quality ordering, adds `Vary: Accept-Encoding`, and returns 406 when neither supported encoding is acceptable. It skips bodyless statuses, empty bodies, `Cache-Control: no-transform`, and already encoded responses. Gzip uses the system zlib implementation at level 6. A SHA-256 keyed LRU retains compressed bodies within a 16 MiB byte budget; a single entry larger than 4 MiB is not cached. The `swift-identity` benchmark sends `Accept-Encoding: identity` to exercise the uncompressed response path.

## Performance

Derived Rails keys are shared across short-lived signers in a process-wide cache of at most 128 entries, keyed by secret, salt and key length. PBKDF2 parameters, cookie verification and signature bytes are unchanged. Signatures and ETags use direct UTF-8 hexadecimal encoding instead of formatting a separate string for each byte.

Message fragment keys and HTTP validators reuse timestamp interpretations in a cache of at most 4,096 entries. Its key is the complete timestamp string; the existing parser's normalization and rounding are preserved. Database reads, writes and fragment invalidation still follow the original routes.

The [before/after benchmark](bench/results/key-cache-20261006/report.md) includes raw measurements, image IDs, validation results and a runner adapted from the Rust HTTP harness. It compares the original Swift image, the optimized image and Rust using the same seed and CPU allocation.
