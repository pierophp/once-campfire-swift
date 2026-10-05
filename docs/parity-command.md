# Swift/Rust response parity

Run the response parity check from the Swift repository root:

```sh
Scripts/compare-parity --build-swift
```

The command copies the selected Rust seed into an independent writable database and storage
directory for every container, logs in as the seeded David user, and requests the harness sequence
currently implemented in Swift: `GET /session/new`, `POST /session`, then `GET /users/me/sidebar`.
It compares the sidebar response; login pages and POST redirect/body envelopes are preconditions,
not part of that route's response surface. It captures normalized responses under the system
temporary directory's `campfire-swift-parity` folder and returns non-zero on any unmasked difference.
The default seed and account come from
`once-campfire-rust/parity/.seed/default/labels.json`.

The default Rust image is `campfire-rust:latest`; override it with `--rust-image`. The Swift image
is `campfire-swift:parity`; use `--swift-image` to select an existing image. `--with-reference`
also compares `campfire-reference:latest`. To point at another Rust checkout or seed directory, set
`CAMPFIRE_RUST_ROOT` and `CAMPFIRE_PARITY_SEED_DIR`.

Docker Desktop users can choose CPUs visible in the Linux VM with `--cpu-set`, for example
`Scripts/compare-parity --build-swift --cpu-set 2-3`. The default is `0,1` and can also be set with
`CAMPFIRE_CPUSET_CPUS`. Each app receives the same setting.

## Normalization

The command compares response status, `Content-Type`, `Cache-Control`, `Last-Modified`, `Vary`,
`Location`, cookie names and attributes, and canonicalized bodies. It requires ETags to be present
with the weak validator form when either side emits one, and checks the 32-hex digest shape; the
digest value is normalized for the reason below.
HTML attributes are sorted and HTML whitespace is collapsed before comparison. Only these values
are normalized:

- Rails CSRF meta tags and authenticity-token fields: Rust omits Rails forgery tokens and the
  harness already handles a missing token by submitting an empty value.
- `Set-Cookie` values and expiration timestamps: Rails encrypts session cookies with random nonces
  and creates independent session tokens. Cookie names and attributes remain compared.
- ISO timestamps in bodies: each server renders request-time values on its own clock; fixed seed
  content, surrounding text and timestamp placement still compare.
- Digests in `/assets/` paths: the Rails and Swift build pipelines fingerprint the same assets
  differently; the logical asset name and extension remain compared.
- ETag digest values: each server hashes its raw HTML before parity canonicalization. Layout
  whitespace, attribute formatting, and asset fingerprints can change those raw bytes, so the
  comparison requires the shared weak-validator format and 32-hex digest shape, while comparing
  the canonicalized body independently.
- `Date`, `Server`, and `X-Request-Id` response headers: these are runtime/request metadata. They
  are excluded from the application header comparison; all listed application headers are checked.

The normalization does not ignore other body differences. Diffs and the full JSON capture are
written to the output directory for diagnosis.
