import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Private, authenticated whole responses, as the Rust and C ports keep them.
///
/// Every request observes the database generation (`SQLiteDatabase.observedGeneration`) before
/// authentication and again at lookup, so a commit by any connection or process during
/// authentication or rendering never serves or stores an old page under the new generation, and
/// the generation is part of the key. Authentication, room access and flash still run on every
/// request; Set-Cookie headers are never stored. Only the completed, bounded identity/gzip
/// representation is retained. `CachedReadHandler` serves hits on the event loop; the route
/// handlers serve them for requests it passes on.
final class ResponseCache: @unchecked Sendable {
    static let maxBody = 1024 * 1024
    private static let maxKeyInput = 8192
    /// Time-dependent output still expires even without a database commit.
    private static let ttlNanoseconds: UInt64 = 15_000_000_000

    let database: SQLiteDatabase
    private let store: ResponseStore?
    private let hitCount = HitCounter()
    private let eventLoopHitCount = HitCounter()
    /// Responses served from the store, for tests: all of them, and those `CachedReadHandler` served.
    var hits: Int { hitCount.value }
    var eventLoopHits: Int { eventLoopHitCount.value }
    var enabled: Bool { store != nil }

    init(database: SQLiteDatabase, maxBytes: Int) {
        self.database = database
        store = maxBytes > 0 ? ResponseStore(byteBudget: maxBytes) : nil
    }

    /// Before authentication, so a session refresh or revocation during it also prevents a hit.
    func begin(_ request: Request, endpoint: StaticString) async -> ResponseCacheRound? {
        guard store != nil, Self.eligible(request.head) else { return nil }
        let database = database
        guard let generation = try? await database.readAsync({ database.observedGeneration($0) }) else { return nil }
        return ResponseCacheRound(generation: generation, endpoint: endpoint)
    }

    /// After authentication. A hit is the stored response; a miss registers the request for
    /// admission by `ResponseCacheMiddleware` once its final representation is known.
    func lookup(_ round: ResponseCacheRound?, request: Request, session: RequestSession, flash: RailsFlash) async -> CachedResponse? {
        guard let round, store != nil, flash.isEmpty else { return nil }
        let database = database
        guard let current = try? await database.readAsync({ database.observedGeneration($0) }), current == round.generation else { return nil }
        guard let key = Self.key(request.head, round: round, session: session) else { return nil }
        if let cached = value(for: key) { return cached }
        // Even if a concurrent commit made this lookup miss, admission checks the version again.
        ResponseCacheSlot.current?.ticket = ResponseCacheTicket(generation: round.generation, key: key)
        return nil
    }

    /// The synchronous lookup `CachedReadHandler` runs on a reader connection it holds: the
    /// generation captured before authentication must still be current after it.
    func lookup(_ head: HTTPRequest, round: ResponseCacheRound, session: RequestSession, connection: SQLiteConnection) -> CachedResponse? {
        guard database.observedGeneration(connection) == round.generation,
              let key = Self.key(head, round: round, session: session), let cached = value(for: key) else { return nil }
        eventLoopHitCount.add()
        return cached
    }

    func round(_ head: HTTPRequest, endpoint: StaticString, connection: SQLiteConnection) -> ResponseCacheRound? {
        guard store != nil, Self.eligible(head), let generation = database.observedGeneration(connection) else { return nil }
        return ResponseCacheRound(generation: generation, endpoint: endpoint)
    }

    private func value(for key: Digest32) -> CachedResponse? {
        guard let store, let cached = store.value(for: key, now: DispatchTime.now().uptimeNanoseconds) else { return nil }
        hitCount.add()
        return cached
    }

    fileprivate func admit(_ ticket: ResponseCacheTicket, _ response: CachedResponse) async {
        guard let store else { return }
        // An entry is keyed by the generation it was rendered in; a later commit makes it
        // unreachable, since every lookup observes the generation first.
        let database = database
        guard let current = try? await database.readAsync({ database.observedGeneration($0) }), current == ticket.generation else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        store.insert(response, for: ticket.key, expiresAt: now + Self.ttlNanoseconds)
    }

    static func eligible(_ head: HTTPRequest) -> Bool {
        let headers = head.headerFields
        return head.method == .get
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
    /// Host and proxy headers, in the order the client sent them (a client that reorders its
    /// headers only misses). Only validators and request tracing headers are left out.
    private static func key(_ head: HTTPRequest, round: ResponseCacheRound, session: RequestSession) -> Digest32? {
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
        field(head.scheme ?? "")
        field(head.authority ?? "")
        field(head.path ?? "")
        for header in head.headerFields {
            let name = header.name.canonicalName
            if unkeyedHeaders.contains(name) { continue }
            field(name)
            field(header.value)
        }
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

extension RailsFlash {
    var isEmpty: Bool { notice == nil && alert == nil && setCookie == nil }
}

/// The four authenticated reads whose finished responses are cached, as routed.
enum CachedRead: Sendable {
    case room(Int64)
    case messages(Int64)
    case sidebar
    case search

    var endpoint: StaticString {
        switch self {
        case .room: "rooms#show"
        case .messages: "messages#index"
        case .sidebar: "users/sidebars#show"
        case .search: "searches#index"
        }
    }

    var roomID: Int64? {
        switch self {
        case .room(let id), .messages(let id): id
        case .sidebar, .search: nil
        }
    }

    /// The route a request path (with its query) reaches, as the router matches it: `:id` is
    /// any single segment, which the handlers read with `Int64(_) ?? 0`.
    init?(path: String) {
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if route == "/users/me/sidebar" { self = .sidebar; return }
        if route == "/searches" { self = .search; return }
        let segments = route.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 3, segments[0].isEmpty, segments[1] == "rooms", !segments[2].isEmpty else { return nil }
        let id = Int64(segments[2]) ?? 0
        if segments.count == 3 { self = .room(id); return }
        if segments.count == 4, segments[3] == "messages" { self = .messages(id); return }
        return nil
    }

    /// The hit as the route handler answers it: its conditional GET and its per-request cookies.
    func response(_ cached: CachedResponse, requestHeaders: HTTPFields, session: RequestSession) -> Response {
        var response: Response
        switch self {
        case .room(let roomID):
            response = cached.response()
            if let cookie = lastRoomCookie(requestHeaders, roomID: roomID) {
                response.headers.append(HTTPField(name: .setCookie, value: cookie))
            }
        case .messages:
            response = cached.response(notModified: cached.etag.map { ifNoneMatch(requestHeaders[HTTPField.Name("if-none-match")!], matches: $0) } ?? false)
        case .sidebar:
            response = cached.response(notModified: cached.etag != nil && requestHeaders[HTTPField.Name("if-none-match")!] == cached.etag)
        case .search:
            response = cached.response()
        }
        SessionPipeline.appendRefreshCookie(session, to: &response)
        return response
    }
}

/// The `last_room` cookie `rooms#show` sets when the request's differs from the room shown.
func lastRoomCookie(_ requestHeaders: HTTPFields, roomID: Int64) -> String? {
    let current = RequestCookies.trimmedItemValue("last_room", in: requestHeaders[.cookie])
    guard current != String(roomID) else { return nil }
    return "last_room=\(roomID); path=/; expires=\(UTCTime.httpDate(UTCTime.twentyYearsFromNow())); samesite=lax"
}

func ifNoneMatch(_ header: String?, matches validator: String) -> Bool {
    guard let header else { return false }
    let target = validator.replacingOccurrences(of: "W/", with: "")
    return header.split(separator: ",").contains { item in
        let candidate = item.trimmingCharacters(in: .whitespaces)
        return candidate == "*" || candidate.replacingOccurrences(of: "W/", with: "") == target
    }
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
        await cache.admit(ticket, CachedResponse(headers: headers, body: body))
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
