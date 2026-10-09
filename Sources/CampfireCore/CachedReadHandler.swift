import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOHTTPTypes

/// Serves cached room, messages, sidebar and search responses on the connection's event loop, the
/// way the C port answers a warm read: one pass over a free reader connection for the generation,
/// the session, room membership and the generation again, then the stored bytes. The request
/// never reaches the async channel bridge, a task or the router.
///
/// Anything it cannot answer from the cache goes on, untouched, to Hummingbird: a miss, flash, a
/// session that must record activity, `Connection: close`, a request body, a busy reader pool,
/// and every request on a connection with an earlier response still being produced (responses
/// must leave in request order). Sits after the HTTP/1 codec, so it sees `HTTPRequestPart`s.
final class CachedReadHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart
    typealias InboundOut = HTTPRequestPart
    typealias OutboundIn = HTTPResponsePart
    typealias OutboundOut = HTTPResponsePart

    private let cache: ResponseCache
    private let serverName: String?
    /// Requests passed on whose response has not finished.
    private var inFlight = 0
    /// A GET held until its end part shows it has no body.
    private var pending: (head: HTTPRequest, read: CachedRead)?

    init(cache: ResponseCache, serverName: String?) {
        self.cache = cache
        self.serverName = serverName
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            if inFlight == 0, pending == nil, cache.enabled, head.method == .get, !Self.closes(head),
               let path = head.path, let read = CachedRead(path: path) {
                pending = (head, read)
                return
            }
            passOn(context: context, part, startsRequest: true)
        case .body:
            if let held = pending.take() { passOn(context: context, .head(held.head), startsRequest: true) }
            context.fireChannelRead(data)
        case .end:
            guard let held = pending.take() else { context.fireChannelRead(data); return }
            if let (response, body) = cachedResponse(held.head, read: held.read) {
                write(response, body: body, context: context)
            } else {
                passOn(context: context, .head(held.head), startsRequest: true)
                context.fireChannelRead(data)
            }
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .end = unwrapOutboundIn(data) { inFlight -= 1 }
        context.write(data, promise: promise)
    }

    /// Hummingbird closes the connection after answering `Connection: close`; leave those to it.
    private static func closes(_ head: HTTPRequest) -> Bool {
        head.headerFields[values: .connection].contains { value in
            value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("close") == .orderedSame }
        }
    }

    private func passOn(context: ChannelHandlerContext, _ part: HTTPRequestPart, startsRequest: Bool) {
        if startsRequest { inFlight += 1 }
        context.fireChannelRead(wrapInboundOut(part))
    }

    /// The route handler's hit response and its body (none for a 304), or nil when the router
    /// must handle the request.
    private func cachedResponse(_ head: HTTPRequest, read: CachedRead) -> (Response, ByteBuffer?)? {
        let headers = head.headerFields
        guard let token = SessionPipeline.token(headers), SessionPipeline.readFlash(headers).isEmpty else { return nil }
        let cache = cache
        let outcome = cache.database.readOnFreeConnection { connection -> (Response, ByteBuffer?)? in
            guard let round = cache.round(head, endpoint: read.endpoint, connection: connection),
                  let session = try SessionPipeline.find(token: token, connection: connection), !session.refreshed else { return nil }
            if let roomID = read.roomID {
                guard try connection.firstRow("SELECT r.id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(roomID), .integer(session.user.id)]) != nil else { return nil }
            }
            guard let cached = cache.lookup(head, round: round, session: session, connection: connection) else { return nil }
            let response = read.response(cached, requestHeaders: headers, session: session)
            return (response, response.status == .ok ? cached.body : nil)
        }
        guard case .success(let response)? = outcome else { return nil }
        return response
    }

    /// As Hummingbird writes a buffered response, with the `Date` and `Server` headers it adds.
    private func write(_ response: Response, body: ByteBuffer?, context: ChannelHandlerContext) {
        var head = response.head
        head.headerFields[.date] = HTTPDateHeader.current()
        if let serverName { head.headerFields[.server] = serverName }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body, body.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(body)), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

/// The IMF-fixdate of the current second, as Hummingbird's date cache provides it.
enum HTTPDateHeader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var second: Int64 = .min
    nonisolated(unsafe) private static var value = ""

    static func current() -> String {
        let now = UTCTime.nowSeconds()
        lock.lock(); defer { lock.unlock() }
        if second != now {
            second = now
            value = UTCTime.httpDate(now)
        }
        return value
    }
}
