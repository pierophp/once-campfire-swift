import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Private, authenticated whole responses, as the Rust and C ports keep them.
///
/// A dedicated read-only SQLite connection observes `PRAGMA data_version`, which changes when
/// any other connection (this process's writer or another process) commits. Its generation is
/// captured before authentication and checked again at lookup and admission, so a commit during
/// authentication or rendering can never store an old render under the new generation.
/// Authentication, room access and flash still run on every request; Set-Cookie headers are
/// never stored. Only the completed, bounded identity/gzip representation is retained.
final class ResponseCache: @unchecked Sendable {
    static let maxBody = 1024 * 1024
    private static let maxKeyInput = 8192
    /// Time-dependent output still expires even without a database commit.
    private static let ttlNanoseconds: UInt64 = 15_000_000_000

    private let observerLock = NSLock()
    private let observer: SQLiteConnection?
    private var dataVersion: Int64 = 0
    private var generation: UInt64 = 0
    private let store: ResponseStore?
    private let hitCount = HitCounter()
    /// Responses served from the store, for tests.
    var hits: Int { hitCount.value }

    init(database: SQLiteDatabase, maxBytes: Int) {
        if maxBytes > 0, let observer = try? database.openObserver(), let version = try? observer.scalarInt("PRAGMA data_version") {
            self.observer = observer
            dataVersion = version
            store = ResponseStore(byteBudget: maxBytes)
        } else {
            observer = nil
            store = nil
        }
    }

    /// The current database generation; nil when the cache is off or the observer failed.
    private func version() -> UInt64? {
        guard let observer else { return nil }
        observerLock.lock(); defer { observerLock.unlock() }
        return observedVersion(observer)
    }

    /// Call with `observerLock` held.
    private func observedVersion(_ observer: SQLiteConnection) -> UInt64? {
        guard let current = try? observer.scalarInt("PRAGMA data_version") else { return nil }
        if current != dataVersion {
            generation &+= 1
            dataVersion = current
        }
        return generation
    }

    /// Before authentication, so a session refresh or revocation during it also prevents a hit.
    func begin(_ request: Request, endpoint: StaticString) -> ResponseCacheRound? {
        guard store != nil, Self.eligible(request), let generation = version() else { return nil }
        return ResponseCacheRound(generation: generation, endpoint: endpoint)
    }

    /// After authentication. A hit is the stored response; a miss registers the request for
    /// admission by `ResponseCacheMiddleware` once its final representation is known.
    func lookup(_ round: ResponseCacheRound?, request: Request, session: RequestSession, flash: RailsFlash) -> CachedResponse? {
        guard let round, let store, let observer, flash.notice == nil, flash.alert == nil, flash.setCookie == nil,
              let key = Self.key(request, round: round, session: session) else { return nil }
        observerLock.lock()
        let current = observedVersion(observer)
        observerLock.unlock()
        guard current == round.generation else { return nil }
        if let cached = store.value(for: key, now: DispatchTime.now().uptimeNanoseconds) {
            hitCount.add()
            return cached
        }
        // Even if a concurrent commit made this lookup miss, admission checks the version again.
        ResponseCacheSlot.current?.ticket = ResponseCacheTicket(generation: round.generation, key: key)
        return nil
    }

    fileprivate func admit(_ ticket: ResponseCacheTicket, _ response: CachedResponse) {
        guard let store, let observer else { return }
        // Version observation and admission stay together: an old render never enters a newer
        // generation, and a later commit makes this one unreachable on the next lookup.
        observerLock.lock(); defer { observerLock.unlock() }
        guard observedVersion(observer) == ticket.generation else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        store.insert(response, for: ticket.key, expiresAt: now + Self.ttlNanoseconds)
    }

    private static func eligible(_ request: Request) -> Bool {
        let headers = request.headers
        return request.method == .get
            && headers[HTTPField.Name("range")!] == nil
            && headers[HTTPField.Name("upgrade")!] == nil
            && !hasDirective(headers[values: .cacheControl], ["no-cache", "no-store"])
            && !(headers[HTTPField.Name("pragma")!].map { $0.caseInsensitiveCompare("no-cache") == .orderedSame } ?? false)
    }

    static func cacheable(_ headers: HTTPFields) -> Bool {
        !hasDirective(headers[values: .cacheControl], ["no-store", "no-transform"])
    }

    private static func hasDirective(_ values: [String], _ rejected: [String]) -> Bool {
        values.contains { value in
            value.split(separator: ",").contains { directive in
                let name = directive.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return rejected.contains { name.caseInsensitiveCompare($0) == .orderedSame }
            }
        }
    }

    private static let unkeyedHeaders: Set<String> = ["if-none-match", "if-modified-since", "x-request-id", "x-request-start"]

    /// Every representation and session variant: cookies, Accept, Accept-Encoding, Turbo-Frame,
    /// Host and proxy headers. Only validators and request tracing headers are left out.
    private static func key(_ request: Request, round: ResponseCacheRound, session: RequestSession) -> Digest32? {
        var hasher = SHA256()
        var length = 0
        func fieldBytes(_ bytes: UnsafeRawBufferPointer) {
            length += bytes.count + 8
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(bufferPointer: bytes)
        }
        func field(_ text: String) { var text = text; text.withUTF8 { fieldBytes(UnsafeRawBufferPointer($0)) } }
        func fieldInteger(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { fieldBytes($0) } }

        fieldInteger(round.generation)
        field(round.endpoint.description)
        fieldInteger(UInt64(bitPattern: session.user.id))
        fieldInteger(UInt64(bitPattern: session.id))
        field(request.head.scheme ?? "")
        field(request.head.authority ?? "")
        field(request.uri.description)
        let fields = request.headers
            .map { (name: $0.name.canonicalName, value: $0.value) }
            .filter { !unkeyedHeaders.contains($0.name) }
            .sorted { $0.name < $1.name }
        var previous: String?
        for header in fields {
            if header.name != previous {
                if previous != nil { field("") }
                field(header.name)
                previous = header.name
            }
            field(header.value)
        }
        if previous != nil { field("") }
        guard length <= maxKeyInput else { return nil }
        return Digest32(hasher.finalize())
    }
}

struct ResponseCacheRound: Sendable {
    let generation: UInt64
    let endpoint: StaticString
}

private struct ResponseCacheTicket: Sendable {
    let generation: UInt64
    let key: Digest32
}

/// A completed 200 response without its cookies.
struct CachedResponse: Sendable {
    let headers: HTTPFields
    let body: ByteBuffer

    var etag: String? { headers[HTTPField.Name("etag")!] }

    /// The stored response, or its 304 when the handler's own validator check matches.
    func response(notModified: Bool = false) -> Response {
        guard notModified else { return Response(status: .ok, headers: headers, body: .init(byteBuffer: body)) }
        var headers = headers
        // A handler's 304 has no body headers, and the deflater leaves it without Vary.
        for name in [HTTPField.Name.contentType, .contentEncoding, .contentLength, .vary] { headers[name] = nil }
        return Response(status: .notModified, headers: headers)
    }
}

/// Set around each request by `ResponseCacheMiddleware`; a handler that missed records where
/// its finished response may be stored.
final class ResponseCacheSlot: @unchecked Sendable {
    @TaskLocal static var current: ResponseCacheSlot?
    fileprivate var ticket: ResponseCacheTicket?
}

/// Outside the deflater: retains exactly the successfully finished representation.
struct ResponseCacheMiddleware: RouterMiddleware {
    let cache: ResponseCache

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        let slot = ResponseCacheSlot()
        var response = try await ResponseCacheSlot.$current.withValue(slot) { try await next(request, context) }
        guard let ticket = slot.ticket, response.status == .ok, ResponseCache.cacheable(response.headers),
              let length = response.body.contentLength, length <= ResponseCache.maxBody else { return response }
        let collector = BufferCollector()
        try await response.body.write(collector)
        let body = collector.buffer
        response.body = .init(byteBuffer: body)
        var headers = response.headers
        for name in ["set-cookie", "date", "x-request-id", "x-runtime", "content-length"] { headers[HTTPField.Name(name)!] = nil }
        cache.admit(ticket, CachedResponse(headers: headers, body: body))
        return response
    }
}

private final class BufferCollector: ResponseBodyWriter, @unchecked Sendable {
    var buffer = ByteBuffer()
    private var written = false
    func write(_ buffer: ByteBuffer) async throws {
        if written { self.buffer.writeImmutableBuffer(buffer) } else { self.buffer = buffer; written = true }
    }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

/// Byte-bounded responses with a deadline each. Entries of older generations are never read
/// again, so CLOCK (second chance) eviction removes them first.
private final class ResponseStore: @unchecked Sendable {
    private struct Entry { let response: CachedResponse; let expiresAt: UInt64; let cost: Int; var referenced: Bool }
    private let lock = NSLock()
    private let byteBudget: Int
    private var bytes = 0
    private var entries: [Digest32: Entry] = [:]
    private var queue: [Digest32] = []
    private var head = 0

    init(byteBudget: Int) { self.byteBudget = byteBudget }

    func value(for key: Digest32, now: UInt64) -> CachedResponse? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            bytes -= entry.cost
            return nil
        }
        if !entry.referenced { entry.referenced = true; entries[key] = entry }
        return entry.response
    }

    func insert(_ response: CachedResponse, for key: Digest32, expiresAt: UInt64) {
        let cost = response.body.readableBytes + response.headers.reduce(0) { $0 + $1.name.canonicalName.utf8.count + $1.value.utf8.count } + 256
        guard cost <= byteBudget / 4 else { return }
        lock.lock(); defer { lock.unlock() }
        if let prior = entries.updateValue(Entry(response: response, expiresAt: expiresAt, cost: cost, referenced: false), forKey: key) {
            bytes -= prior.cost
        } else {
            queue.append(key)
        }
        bytes += cost
        while bytes > byteBudget && head < queue.count {
            let candidate = queue[head]; head += 1
            guard var victim = entries[candidate] else { continue }
            if victim.referenced {
                victim.referenced = false
                entries[candidate] = victim
                queue.append(candidate)
            } else {
                bytes -= victim.cost
                entries.removeValue(forKey: candidate)
            }
        }
        if head > 1_024 && head * 2 > queue.count { queue.removeFirst(head); head = 0 }
    }
}

private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
