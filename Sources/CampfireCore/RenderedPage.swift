import Crypto
import Foundation
import Hummingbird
import NIOCore

/// A rendered message partial. Its HTML never changes, and its `id` is unique for the process,
/// so a page can name the fragment instead of hashing its bytes.
final class MessageFragment: Sendable {
    let html: String
    let id: UInt64
    let byteCount: Int

    init(html: String) {
        self.html = html
        self.byteCount = html.utf8.count
        self.id = MessageFragment.nextID()
    }

    private static let counter = FragmentCounter()
    private static func nextID() -> UInt64 { counter.next() }
}

private final class FragmentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
}

/// A page body as text runs and cached fragments, in order.
///
/// Room, message and search pages are mostly cached fragments, and pages repeat until what they
/// show changes. Their `identity` hashes the text and the fragments' ids (a tenth of the bytes),
/// which keys a memo of the ETag (SHA-256 of the whole body, as `Rack::ETag` computes it) and the
/// gzip cache. The body itself is joined only when it is actually sent uncompressed or first
/// compressed. A page without fragments is identified by the SHA-256 of its body, which is also
/// its ETag digest.
struct RenderedPage: Sendable {
    enum Part: Sendable {
        case text(ByteBuffer)
        case fragment(MessageFragment)
    }

    let parts: [Part]
    let length: Int
    let identity: BodyIdentity

    init(parts: [Part], length: Int) {
        self.parts = parts
        self.length = length
        if parts.contains(where: { if case .fragment = $0 { return true } else { return false } }) {
            var hasher = SHA256()
            for part in parts {
                switch part {
                case .text(let text):
                    hasher.update(data: [0])
                    withUnsafeBytes(of: UInt64(text.readableBytes).littleEndian) { hasher.update(bufferPointer: $0) }
                    text.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                case .fragment(let fragment):
                    hasher.update(data: [1])
                    withUnsafeBytes(of: fragment.id.littleEndian) { hasher.update(bufferPointer: $0) }
                }
            }
            identity = .parts(Digest32(hasher.finalize()))
        } else {
            var hasher = SHA256()
            for case .text(let text) in parts { text.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) } }
            identity = .body(Digest32(hasher.finalize()))
        }
    }

    /// The whole body in one buffer.
    func materialize() -> ByteBuffer {
        if parts.count == 1, case .text(let text) = parts[0] { return text }
        var body = ByteBufferAllocator().buffer(capacity: length)
        for part in parts {
            switch part {
            case .text(let text): body.writeImmutableBuffer(text)
            case .fragment(let fragment): body.writeString(fragment.html)
            }
        }
        return body
    }

    /// `W/"<first 32 hex digits of SHA-256(body)>"`, the same value `etag(for:)` gives the joined body.
    func etag() -> String {
        switch identity {
        case .body(let digest): return digest.weakETag
        case .parts(let key):
            if let cached = Self.etags.value(for: key) { return cached }
            let value = CampfireCore.etag(for: materialize())
            Self.etags.insert(value, for: key)
            return value
        }
    }

    /// A body joined only when written, which registers the page's identity with the gzip
    /// middleware so a cached compression can be reused without reading the body.
    func responseBody() -> ResponseBody {
        ResponseBodyIdentity.current?.identity = identity
        let page = self
        return ResponseBody(contentLength: length) { writer in
            try await writer.write(page.materialize())
            try await writer.finish(nil)
        }
    }

    private static let etags = BoundedCache<Digest32, String>(limit: 65_536)
}

enum BodyIdentity: Hashable, Sendable {
    /// SHA-256 of the body.
    case body(Digest32)
    /// SHA-256 over the page's parts, with fragments by id.
    case parts(Digest32)
}

struct Digest32: Hashable, Sendable {
    private let a: UInt64, b: UInt64, c: UInt64, d: UInt64

    init(_ digest: SHA256.Digest) {
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        digest.withUnsafeBytes { bytes in
            withUnsafeMutableBytes(of: &words) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes.prefix(32))) }
        }
        (a, b, c, d) = words
    }

    var weakETag: String {
        let bytes = withUnsafeBytes(of: (a, b)) { Array($0) }
        return "W/\"\(hexEncoded(bytes))\""
    }
}

/// Set by the gzip middleware around each request; a handler that knows its body's identity
/// records it so the middleware can find the compressed body without reading the plain one.
final class ResponseBodyIdentity: @unchecked Sendable {
    @TaskLocal static var current: ResponseBodyIdentity?
    var identity: BodyIdentity?
}
