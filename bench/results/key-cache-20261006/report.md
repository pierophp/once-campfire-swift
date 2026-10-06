# Swift performance improvements — 2026-10-06

Three repetitions per image; 16 concurrent keep-alive clients; 8 seconds measured after 2 seconds of warmup per workload. Server CPUs: 0–3; load generator: 4–7; host networking. Each run resets a copy of the same Rust default seed. App order reverses on even repetitions.

Host: Intel Core i7-1255U, 12 hardware threads, 23 GB RAM. These results compare the implementations on this host; the published Basecamp table uses different hardware.

## HTTP throughput

Cells are median [minimum–maximum] requests/second.

| Workload | Swift original | Swift optimized | Rust | Swift gain |
|---|---:|---:|---:|---:|
| room_show | 111.7 [109.4–121.8] | 1,465.3 [1,427.6–1,471.5] | 14,669.2 [14,640.9–14,819.9] | 13.1× |
| messages_page | 94.0 [93.3–101.2] | 2,926.3 [2,794.7–2,950.5] | 16,758.7 [16,756.2–16,873.8] | 31.1× |
| sidebar | 44.7 [43.8–46.8] | 3,797.6 [3,755.8–3,840.4] | 13,451.3 [13,363.8–13,461.7] | 85.0× |
| search | 323.6 [317.9–334.4] | 4,356.6 [4,347.3–4,396.9] | 13,201.0 [13,167.6–13,646.3] | 13.5× |
| post_message | 116.6 [111.5–119.7] | 288.6 [272.8–303.3] | 3,083.9 [3,031.0–3,086.7] | 2.5× |

All five workloads returned HTTP 200 with zero transport errors in every measured repetition.

## Latency

| Workload | Original p50 / p90 / p99 (ms) | Optimized p50 / p90 / p99 (ms) | Rust p50 / p90 / p99 (ms) |
|---|---:|---:|---:|
| room_show | 142.21 / 155.01 / 168.70 | 10.90 / 12.02 / 13.23 | 1.06 / 1.48 / 1.89 |
| messages_page | 169.85 / 182.27 / 194.43 | 5.42 / 6.12 / 6.97 | 0.94 / 1.26 / 1.56 |
| sidebar | 357.63 / 418.81 / 456.45 | 4.03 / 5.05 / 6.52 | 1.15 / 1.64 / 2.12 |
| search | 49.25 / 57.44 / 63.55 | 3.46 / 4.64 / 6.04 | 1.15 / 1.67 / 2.27 |
| post_message | 136.83 / 154.24 / 170.24 | 49.57 / 69.18 / 268.29 | 4.69 / 7.34 / 10.93 |

## Startup and memory

| Metric | Swift original | Swift optimized | Rust |
|---|---:|---:|---:|
| Cold start (ms) | 160.0 [160.0–458.0] | 160.0 [159.0–161.0] | 470.0 [173.0–572.0] |
| Idle cgroup memory (MiB) | 5.0 [5.0–5.0] | 5.0 [5.0–5.0] | 15.0 [15.0–15.0] |
| Idle anonymous memory (MiB) | 4.0 [4.0–4.0] | 4.0 [4.0–4.0] | 13.0 [13.0–13.0] |
| Peak sampled cgroup memory (MiB) | 85.0 [82.0–85.0] | 155.0 [152.0–159.0] | 142.0 [142.0–144.0] |
| Peak sampled anonymous memory (MiB) | 43.0 [40.0–44.0] | 110.0 [108.0–111.0] | 91.0 [91.0–92.0] |

One-minute load average at run starts ranged from 1.84 to 5.45; normal host activity contributes measurement noise.

## Changes and validation

- PBKDF2 keys are retained across signer instances in a bounded cache keyed by secret, salt and length. The original iteration count and digest remain unchanged.
- Digest hexadecimal encoding uses UTF-8 bytes, preserving exact signatures and ETags.
- Immutable timestamp interpretations are memoized with a 4,096-entry limit. The existing date parser and rounding remain unchanged, and no database rows or HTTP responses are cached by this change.
- 36 release-mode tests passed in Swift 6.4 Linux, with the seed required and no skipped integration tests.
- Original and optimized read responses matched byte-for-byte with identical Host inputs; selected headers and ETags also matched. See `response-parity.json`.

The `crypto-only/` directory contains the first complete intermediate repetition. It showed that crypto reuse alone improved the sidebar greatly but left timestamp parsing as a bottleneck for message pages. Interrupted samples were excluded.

## Reproduce

Build with the repository Dockerfile and run the command in `command.txt`. The original image is from commit `65a938d`; the optimized image includes the local changes. Image IDs, settings and source checksums are in `settings.json` and `env.txt`. `run-http` copies the Rust harness at `ccece30`, adding Swift image aliases and limiting measurement to the five published HTTP workloads.

Action Cable, uploads and auxiliary asset routes are excluded. The previously observed Swift stylesheet 404 remains outside this performance change.

```text
date: 2026-10-06T10:08:41-03:00
host: 7.2.5-3-omarchy, 12th Gen Intel(R) Core(TM) i7-1255U, 12 threads, 23GB
server cpus: 0-3 (nproc 4); loadgen cpus: 4-7; network: host
env: WEB_CONCURRENCY=3 JOB_CONCURRENCY=3 RAILS_MAX_THREADS=5
rust extra env:
user agent: (none)
swift-before image: campfire-swift:baseline-65a938d sha256:0688660d303b41a662a09be23f28af36eb0a60d11e3e2917eefa8684a50845f2 2026-10-06T09:14:25.113447932-03:00
swift-after image: campfire-swift:optimized sha256:34bf461f0f3d123b8e2c35fb38ca5770245f39fa27bd747963827923a9d41d29 2026-10-06T10:06:50.213543617-03:00
rust image: campfire-rust:app sha256:8682df2431bce38498053c41bb20ad56dc4634fe306d092d8b861afa53138ba3 2026-10-06T09:03:16.436567739-03:00
rust HEAD: ccece30 (dirty: 0 files)
```
