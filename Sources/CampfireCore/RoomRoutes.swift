import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

struct RoomMessage: Sendable {
    let id: Int64
    let clientMessageID: String
    let roomID: Int64
    let createdAt: String
    let updatedAt: String
    let createdAtMilliseconds: Int64
    let creatorID: Int64
    let creatorName: String
    let creatorUpdatedAt: String
    let creatorTitle: String
    let roomName: String
    let body: String
    let boosts: [RoomBoost]
}

struct RoomBoost: Sendable {
    let id: Int64
    let messageID: Int64
    let content: String
    let creatorID: Int64
    let creatorName: String
    let creatorUpdatedAt: String
    let creatorTitle: String
}

struct MessageVersion: Sendable {
    let id: Int64
    let createdAt: String
    let updatedAt: String
    let createdAtMilliseconds: Int64
}

/// Byte-bounded cache for Rails-style message partials. The lookup happens before loading a
/// message's creator, rich text, boosts, or building the per-message presentation value.
/// Eviction is CLOCK (second chance): recently read entries survive one pass of the hand.
final class MessageFragmentCache: @unchecked Sendable {
    private struct Entry { let fragment: MessageFragment; let bytes: Int; var referenced: Bool }
    private let maxBytes: Int
    private let lock = NSLock()
    private var entries: [MessageFragmentKey: Entry] = [:]
    private var queue: [MessageFragmentKey] = []
    private var head = 0
    private var bytes = 0

    init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    /// One lock acquisition for a page of keys; misses are nil.
    func values(for keys: [MessageFragmentKey]) -> [MessageFragment?] {
        lock.lock(); defer { lock.unlock() }
        return keys.map(touch)
    }

    private func touch(_ key: MessageFragmentKey) -> MessageFragment? {
        guard var entry = entries[key] else { return nil }
        if !entry.referenced { entry.referenced = true; entries[key] = entry }
        return entry.fragment
    }

    func insert(_ html: String, for key: MessageFragmentKey) -> MessageFragment {
        let fragment = MessageFragment(html: html)
        let cost = key.byteCount + fragment.byteCount + 240
        guard cost <= maxBytes / 4 else { return fragment }
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[key] { return existing.fragment }
        while bytes + cost > maxBytes && head < queue.count {
            let candidate = queue[head]; head += 1
            guard var victim = entries[candidate] else { continue }
            if victim.referenced {
                victim.referenced = false
                entries[candidate] = victim
                queue.append(candidate)
            } else {
                bytes -= victim.bytes
                entries.removeValue(forKey: candidate)
            }
        }
        if head > 1_024 && head * 2 > queue.count { queue.removeFirst(head); head = 0 }
        entries[key] = Entry(fragment: fragment, bytes: cost, referenced: false)
        queue.append(key)
        bytes += cost
        return fragment
    }
}

func installRoomRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase, fragmentCache: MessageFragmentCache) {
    router.post("/rooms/:id/messages") { request, context async throws -> Response in
        let remoteAddress = request.headers[HTTPField.Name("x-forwarded-for")!]?.split(separator: ",").first.map(String.init) ?? "127.0.0.1"
        let banned = try await database.readAsync { connection in
            try connection.firstRow("SELECT 1 FROM bans WHERE ip_address=? LIMIT 1", bindings: [.text(remoteAddress)]) != nil
        }
        if banned { return Response(status: .tooManyRequests) }

        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }
        guard allowsSameOrigin(request) else { return Response(status: .init(code: 422)) }
        guard (request.headers[.accept] ?? "").contains("text/vnd.turbo-stream.html") else {
            return Response(status: .init(code: 406))
        }

        let roomID = Int64(context.parameters.get("id") ?? "") ?? 0
        let room = try await database.readAsync { connection in
            try connection.firstRow("SELECT r.id, r.name, r.type FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(roomID), .integer(session.user.id)])
        }
        guard let room, let storedRoomID = room.integer(0), let roomType = room.string(2) else {
            var response = Response(status: .found)
            response.headers[.location] = "/"
            if let cookie = SessionPipeline.alertCookie("Room not found or inaccessible") {
                response.headers.append(HTTPField(name: .setCookie, value: cookie))
            }
            return response
        }

        var request = request
        let form = formParameters(try await request.collectBody(upTo: 64 * 1024))
        let body = form["message[body]"]
        let clientMessageID = form["message[client_message_id]"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? UUID().uuidString.lowercased()
        let createdAt = sqliteTimestamp()
        let plainText = body.map(AppSecrets.actionText.plainText) ?? ""
        let messageID = try await database.writeAsync { connection, hooks in
            let inserted = try connection.firstRow("INSERT INTO messages (client_message_id, created_at, creator_id, room_id, updated_at) VALUES (?, ?, ?, ?, ?) RETURNING id", bindings: [.text(clientMessageID), .text(createdAt), .integer(session.user.id), .integer(storedRoomID), .text(createdAt)])
            guard let id = inserted?.integer(0) else { throw SQLiteError.query("Message insert did not return its id") }
            if let body {
                let bodyAt = sqliteTimestamp()
                try connection.execute("INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)", bindings: [.text(body), .text(bodyAt), .integer(id), .text(bodyAt)])
                try connection.execute("UPDATE messages SET updated_at=? WHERE id=?", bindings: [.text(sqliteTimestamp()), .integer(id)])
            }
            try connection.execute("UPDATE rooms SET updated_at=? WHERE id=?", bindings: [.text(sqliteTimestamp()), .integer(storedRoomID)])

            hooks.append { writer in
                try writer.execute("INSERT INTO message_search_index(rowid, body) VALUES (?, ?)", bindings: [.integer(id), .text(plainText)])
                try writer.execute("UPDATE memberships SET unread_at=?, updated_at=? WHERE room_id=? AND involvement!='invisible' AND (connected_at IS NULL OR connected_at < datetime('now', '-1 minute')) AND user_id!=?", bindings: [.text(createdAt), .text(sqliteTimestamp()), .integer(storedRoomID), .integer(session.user.id)])
            }
            return id
        }

        // Rails enqueues this after the post-commit unread updates. Delivery is intentionally a
        // no-op because the parity seed has no live push endpoints.
        MessagePushJobQueue.enqueue(roomID: storedRoomID, messageID: messageID)

        let rendered = try await database.readAsync { connection -> MessageFragment in
            guard let row = try connection.firstRow("SELECT created_at, updated_at FROM messages WHERE id=?", bindings: [.integer(messageID)]),
                  let created = row.string(0), let updated = row.string(1) else {
                throw SQLiteError.query("Inserted message was not found after commit")
            }
            let version = MessageVersion(id: messageID, createdAt: created, updatedAt: updated, createdAtMilliseconds: timestampMicroseconds(created) / 1000)
            let message = try loadMessage(connection, version: version, roomName: room.string(1) ?? "", roomID: storedRoomID)
            let rendered = fragmentCache.insert(render(message: message), for: messageFragmentKey(version))

            // The room's message callback reads the memberships used for broadcasts and finds any
            // bot webhook recipients after the fragment has been rendered into cache.
            _ = try connection.rows("SELECT id, user_id, unread_at FROM memberships WHERE room_id=? AND involvement!='invisible' AND unread_at IS NOT NULL", bindings: [.integer(storedRoomID)])
            _ = try connection.rows("SELECT DISTINCT u.id FROM users u INNER JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND u.status=0 AND u.role=2", bindings: [.integer(storedRoomID)]).compactMap { $0.integer(0) }
            return rendered
        }

        let roomKind = roomType == "Rooms::Direct" ? "rooms_direct" : (roomType == "Rooms::Closed" ? "rooms_closed" : "rooms_open")
        var stream = RenderBuffer()
        stream.write("<turbo-stream action=\"append\" target=\"messages_\(roomKind)_\(storedRoomID)\"><template>")
        stream.write(rendered.html)
        stream.write("</template></turbo-stream>")
        let streamBody = stream.finish()
        var response = Response(status: .ok, body: streamBody.responseBody())
        response.headers[.contentType] = "text/vnd.turbo-stream.html; charset=utf-8"
        response.headers[HTTPField.Name("cache-control")!] = "max-age=0, private, must-revalidate"
        response.headers[HTTPField.Name("etag")!] = streamBody.etag()
        response.headers[.vary] = "Accept"
        SessionPipeline.appendRefreshCookie(session, to: &response)
        return response
    }

    router.get("/rooms/:id/messages") { request, context async throws -> Response in
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }

        let roomID = Int64(context.parameters.get("id") ?? "") ?? 0
        let beforeID = request.uri.queryParameters["before"].flatMap { Int64($0) }
        let page = try await database.readAsync { connection -> (String?, [MessageVersion], [MessageFragment]) in
            let room = try connection.firstRow("SELECT r.name FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(roomID), .integer(session.user.id)])
            guard let roomName = room?.string(0) else { return (nil, [], []) }

            let messages: [SQLiteRow]
            if let beforeID {
                guard let timestamp = try connection.firstRow("SELECT created_at FROM messages WHERE id=? AND room_id=? LIMIT 1", bindings: [.integer(beforeID), .integer(roomID)])?.string(0) else {
                    return (roomName, [], [])
                }
                messages = try connection.rows("SELECT id, client_message_id, created_at, updated_at FROM messages WHERE room_id=? AND created_at < ? ORDER BY created_at DESC LIMIT 40", bindings: [.integer(roomID), .text(timestamp)])
            } else {
                messages = try connection.rows("SELECT id, client_message_id, created_at, updated_at FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40", bindings: [.integer(roomID)])
            }
            // Both pages are the 40 before a point, newest first; Rails reverses them.
            let versions = try pageVersions(connection, newestFirst: messages)
            guard !versions.isEmpty else { return (roomName, [], []) }
            let fragments = try messageFragments(connection, versions: versions, fragmentCache: fragmentCache) { _ in (roomName, roomID) }
            return (roomName, versions, fragments)
        }

        guard page.0 != nil else {
            var response = Response(status: .found)
            response.headers[.location] = "/"
            if let cookie = SessionPipeline.alertCookie("Room not found or inaccessible") {
                response.headers.append(HTTPField(name: .setCookie, value: cookie))
            }
            return response
        }
        guard !page.1.isEmpty else { return Response(status: .noContent) }

        var output = RenderBuffer()
        for fragment in page.2 { output.write(fragment) }

        let cacheKeyVersions = page.1.map { "messages/\($0.id)-\(timestampMicroseconds($0.updatedAt))" }.joined(separator: "/")
        let validator = etag(for: "\(cacheKeyVersions)/messages/index")
        let latestModified = page.1.map { timestampMicroseconds($0.updatedAt) }.max() ?? 0
        let lastModified = httpDate(Date(timeIntervalSince1970: Double(latestModified) / 1_000_000))
        var response: Response
        if ifNoneMatch(request.headers[HTTPField.Name("if-none-match")!], matches: validator) {
            response = Response(status: .notModified)
        } else {
            response = Response(status: .ok, body: output.finish().responseBody())
            response.headers[.contentType] = "text/html; charset=utf-8"
        }
        response.headers[HTTPField.Name("etag")!] = validator
        response.headers[HTTPField.Name("last-modified")!] = lastModified
        response.headers[HTTPField.Name("cache-control")!] = "max-age=0, private, must-revalidate"
        SessionPipeline.appendRefreshCookie(session, to: &response)
        return response
    }

    router.get("/rooms/:id") { request, context async throws -> Response in
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }
        let roomID = Int64(context.parameters.get("id") ?? "") ?? 0
        let lastRoomID = SidebarLayout.lastRoomCookie(request)
        let result = try await database.readAsync { connection -> RoomPage? in
            guard let room = try connection.firstRow("SELECT r.id, r.name, r.type, r.updated_at, r.creator_id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(roomID), .integer(session.user.id)]),
                  let returnedID = room.integer(0) else { return nil }
            let messages = try connection.rows("SELECT id, client_message_id, created_at, updated_at FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40", bindings: [.integer(roomID)])
            let originalID = try connection.firstRow("SELECT id FROM rooms ORDER BY created_at ASC LIMIT 1")?.integer(0)
            let hasOlderMessages = try connection.firstRow("SELECT 1 FROM messages WHERE room_id=? LIMIT 1 OFFSET 40", bindings: [.integer(roomID)]) != nil
            let versions = try pageVersions(connection, newestFirst: messages)
            let layout = try SidebarLayout.load(connection: connection, lastRoomCookie: lastRoomID, user: session.user)
            let roomName = room.string(1) ?? ""
            let fragments = try messageFragments(connection, versions: versions, fragmentCache: fragmentCache) { _ in (roomName, returnedID) }
            let joinCode = originalID == roomID && !hasOlderMessages
                ? try connection.firstRow("SELECT join_code FROM accounts ORDER BY id ASC LIMIT 1")?.string(0) ?? ""
                : nil
            let directNames = room.string(2) == "Rooms::Direct"
                ? try connection.rows("SELECT u.name FROM memberships m INNER JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id!=? AND u.status=0 ORDER BY u.name", bindings: [.integer(returnedID), .integer(session.user.id)]).compactMap { $0.string(0) }
                : []
            return RoomPage(room: room, id: returnedID, layout: layout, fragments: fragments, joinCode: joinCode, directNames: directNames)
        }

        guard let result else {
            var response = Response(status: .found)
            response.headers[.location] = "/"
            if let cookie = SessionPipeline.alertCookie("Room not found or inaccessible") {
                response.headers.append(HTTPField(name: .setCookie, value: cookie))
            }
            return response
        }

        let room = result.room
        let returnedID = result.id
        let flash = SessionPipeline.readFlash(request)
        let joinCode = result.joinCode
        let welcomeHTML = joinCode.map { joinCode in "<div id=\"system_welcome\" class=\"message message--formatted txt-align-center center\"><div class=\"message__body center\"><div class=\"message__body-content position-relative\"><p><strong>Welcome to Campfire</strong><br>To invite people to chat, share the join link below.</p><a href=\"/join/\(erbEscape(joinCode))\">\(erbEscape(joinCode))</a></div></div></div>" }

        let roomName = room.string(1) ?? ""
        let direct = room.string(2) == "Rooms::Direct"
        let roomKind = direct ? "rooms_direct" : (room.string(2) == "Rooms::Closed" ? "rooms_closed" : "rooms_open")
        let roomPath = direct ? "directs" : (room.string(2) == "Rooms::Closed" ? "closeds" : "opens")
        let displayName: String
        if direct {
            displayName = result.directNames.isEmpty ? session.user.name : result.directNames.joined(separator: " and ")
        } else { displayName = roomName }
        let roomGID = base64URL(Data("gid://campfire/\(room.string(2) ?? "Rooms::Open")/\(returnedID)".utf8).base64EncodedString(), padded: false)
        let streamName = AppSecrets.turboStreamName("\(roomGID):messages")
        let origin = "http://\(request.head.authority ?? "localhost")"
        let head = "<meta name=\"turbo-cache-control\" content=\"no-preview\"><meta name=\"current-room-id\" content=\"\(returnedID)\">"
        let navPrefix = "<span class=\"btn btn--reversed btn--faux room--current\"><h1 class=\"room__contents txt-medium overflow-ellipsis\">\(direct ? "<span class=\"for-screen-reader\">Ping with</span>" : "")\(erbEscape(displayName))</h1></span><a class=\"btn\" data-room-id=\"\(returnedID)\" href=\"/rooms/\(roomPath)/\(returnedID)/edit\" style=\"view-transition-name: edit-room-\(returnedID)\"><img aria-hidden=\"true\" src=\"\(roomAsset("menu-dots-horizontal.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Settings for this \(direct ? "Ping" : "room")</span></a><span><span class=\"button_to_change_notifying\" data-controller=\"notifications\" data-notifications-attention-class=\"btn--pulsing\" data-notifications-subscriptions-url-value=\"/users/me/push_subscriptions\"><turbo-frame data-controller=\"turbo-frame\" data-action=\"notifications:ready@window-&gt;turbo-frame#load\" data-turbo-frame-url-param=\"/rooms/\(returnedID)/involvement\" id=\"involvement_\(roomKind)_\(returnedID)\"><button class=\"btn\" data-action=\"click-&gt;notifications#attemptToSubscribe\" data-notifications-target=\"bell\"><img aria-hidden=\"true\" src=\"\(roomAsset("notification-bell-loading.svg"))\" width=\"20\" height=\"20\"><img aria-hidden=\"true\" hidden=\"hidden\" src=\"\(roomAsset("notification-bell-alert.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Notification settings for this \(direct ? "Ping" : "room")</span></button></turbo-frame>"
        // The notification dialog sits inside the bell's two closing spans.
        let navWithDialog = navPrefix + renderNotificationDialog(origin: origin) + "</span></span>"
        let footer = renderComposer(roomID: returnedID, origin: origin)
        let loadedAt = timestampMicroseconds(room.string(3) ?? "") / 1000
        let body = SidebarRenderer.render(user: session.user, account: result.layout.account, lastRoomID: result.layout.lastRoomID, shared: [], directs: [], placeholders: [], canCreateRooms: false, flash: flash, pageTitle: displayName, pageHead: head, pageNav: navWithDialog, pageContentWriter: { buffer in
            writeMessageArea(into: &buffer, roomID: returnedID, roomKind: roomKind, welcomeHTML: welcomeHTML, fragments: result.fragments, loadedAt: loadedAt, streamName: streamName, origin: origin, user: session.user)
        }, pageFooter: footer, pageBodyClass: "sidebar", lazySidebar: true)
        var response = Response(status: .ok, body: body.responseBody())
        response.headers[.contentType] = "text/html; charset=utf-8"
        response.headers[HTTPField.Name("cache-control")!] = "max-age=0, private, must-revalidate"
        response.headers[HTTPField.Name("etag")!] = body.etag()
        if let cookie = lastRoomCookie(request: request, roomID: returnedID) {
            response.headers.append(HTTPField(name: .setCookie, value: cookie))
        }
        SessionPipeline.appendRefreshCookie(session, to: &response)
        if let flashCookie = flash.setCookie { response.headers.append(HTTPField(name: .setCookie, value: flashCookie)) }
        return response
    }
}

private struct RoomPage: Sendable {
    let room: SQLiteRow
    let id: Int64
    let layout: SidebarLayout
    let fragments: [MessageFragment]
    /// Present when the welcome banner shows: the original room with no older messages.
    let joinCode: String?
    let directNames: [String]
}

private func ifNoneMatch(_ header: String?, matches validator: String) -> Bool {
    guard let header else { return false }
    let target = validator.replacingOccurrences(of: "W/", with: "")
    return header.split(separator: ",").contains { item in
        let candidate = item.trimmingCharacters(in: .whitespaces)
        return candidate == "*" || candidate.replacingOccurrences(of: "W/", with: "") == target
    }
}

private enum MessagePushJobQueue {
    private static let queue = DispatchQueue(label: "campfire.message-push-jobs", qos: .utility)

    static func enqueue(roomID: Int64, messageID: Int64) {
        queue.async { _ = (roomID, messageID) }
    }
}

private func sqliteTimestamp() -> String { UTCTime.sqliteNow() }

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private func loadSidebarData(database: SQLiteDatabase, user: SignedInUser) async throws -> SidebarData {
    try await Task.detached {
        try database.read { connection -> SidebarData in
            let memberships = try connection.rows("SELECT m.room_id, m.unread_at, r.name, r.type, r.updated_at FROM memberships m INNER JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND m.involvement!='invisible' ORDER BY LOWER(r.name)", bindings: [.integer(user.id)])
            var shared: [SidebarRoom] = [], directs: [SidebarDirect] = []
            for row in memberships {
                guard let id = row.integer(0), let type = row.string(3) else { continue }
                if type == "Rooms::Direct" {
                    let users = try connection.rows("SELECT u.id, u.name, u.updated_at FROM memberships m INNER JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id!=? AND u.status=0", bindings: [.integer(id), .integer(user.id)]).compactMap { row -> SidebarUser? in
                        guard let id = row.integer(0), let name = row.string(1) else { return nil }
                        return SidebarUser(id: id, name: name, updatedAt: row.string(2) ?? "")
                    }
                    directs.append(SidebarDirect(id: id, unread: row.string(1) != nil, updatedAt: "0", members: users.isEmpty ? [SidebarUser(id: user.id, name: user.name, updatedAt: user.updatedAt)] : users))
                } else { shared.append(SidebarRoom(id: id, name: row.string(2) ?? "", type: type, unread: row.string(1) != nil, updatedAtEpoch: "0")) }
            }
            let excluded = try connection.rows("SELECT DISTINCT m.user_id FROM memberships m INNER JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND r.type='Rooms::Direct'", bindings: [.integer(user.id)]).compactMap { $0.integer(0) } + [user.id]
            let placeholders = try connection.rows("SELECT id, name, updated_at FROM users WHERE status=0 AND id NOT IN (\(excluded.map { _ in "?" }.joined(separator: ","))) ORDER BY name LIMIT 20", bindings: excluded.map(SQLiteValue.integer)).compactMap { row -> SidebarUser? in
                guard let id = row.integer(0), let name = row.string(1) else { return nil }
                return SidebarUser(id: id, name: name, updatedAt: row.string(2) ?? "")
            }
            let settings = try connection.firstRow("SELECT settings FROM accounts ORDER BY id LIMIT 1")?.string(0)
            let restricted = settings.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["restrict_room_creation_to_administrators"] as? Bool ?? false
            return SidebarData(shared: shared, directs: directs, placeholders: placeholders, canCreateRooms: !restricted || user.role == 1)
        }
    }.value
}

func loadMessage(_ connection: SQLiteConnection, version: MessageVersion, roomName: String, roomID: Int64) throws -> RoomMessage {
    let row = try connection.firstRow("SELECT m.creator_id, u.name, u.updated_at, COALESCE(t.body,''), m.created_at, m.client_message_id, u.bio FROM messages m INNER JOIN users u ON u.id=m.creator_id LEFT JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' WHERE m.id=? LIMIT 1", bindings: [.integer(version.id)])
    let creatorID = row?.integer(0) ?? 0
    let boosts = try connection.rows("SELECT b.id, b.message_id, b.content, u.id, u.name, u.updated_at, u.bio FROM boosts b INNER JOIN users u ON u.id=b.booster_id WHERE b.message_id=? ORDER BY b.created_at, b.id", bindings: [.integer(version.id)]).compactMap { row -> RoomBoost? in
        guard let id = row.integer(0), let messageID = row.integer(1), let creatorID = row.integer(3) else { return nil }
        let creatorName = row.string(4) ?? ""
        return RoomBoost(id: id, messageID: messageID, content: row.string(2) ?? "", creatorID: creatorID, creatorName: creatorName, creatorUpdatedAt: row.string(5) ?? "", creatorTitle: [creatorName, row.string(6)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – "))
    }
    return RoomMessage(id: version.id, clientMessageID: row?.string(5) ?? String(version.id), roomID: roomID, createdAt: version.createdAt, updatedAt: version.updatedAt, createdAtMilliseconds: version.createdAtMilliseconds, creatorID: creatorID, creatorName: row?.string(1) ?? "", creatorUpdatedAt: row?.string(2) ?? "", creatorTitle: [row?.string(1), row?.string(6)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – "), roomName: roomName, body: row?.string(3) ?? "", boosts: boosts)
}

/// Message partial HTML for a page of versions, in order: cached fragments are fetched under one
/// lock and only misses load their message rows and render.
func messageFragments(_ connection: SQLiteConnection, versions: [MessageVersion], fragmentCache: MessageFragmentCache, room: (Int) -> (name: String, id: Int64)) throws -> [MessageFragment] {
    let keys = versions.map(messageFragmentKey)
    let cached = fragmentCache.values(for: keys)
    var fragments: [MessageFragment] = []
    fragments.reserveCapacity(versions.count)
    for index in versions.indices {
        if let html = cached[index] { fragments.append(html); continue }
        let (roomName, roomID) = room(index)
        let message = try loadMessage(connection, version: versions[index], roomName: roomName, roomID: roomID)
        fragments.append(fragmentCache.insert(render(message: message), for: keys[index]))
    }
    return fragments
}

/// Message versions oldest first from rows `id, client_message_id, created_at, updated_at`
/// queried newest first.
private func pageVersions(_ connection: SQLiteConnection, newestFirst rows: [SQLiteRow]) throws -> [MessageVersion] {
    try rows.reversed().compactMap { row -> MessageVersion? in
        guard let id = row.integer(0), let created = row.string(2), let updated = row.string(3) else { return nil }
        return MessageVersion(id: id, createdAt: created, updatedAt: updated, createdAtMilliseconds: try sqliteEpochMilliseconds(connection, created))
    }
}

/// The epoch milliseconds the message partial shows (`data-message-timestamp`), as SQLite computes them.
private func sqliteEpochMilliseconds(_ connection: SQLiteConnection, _ timestamp: String) throws -> Int64 {
    if let value = UTCTime.sqliteEpochMilliseconds(timestamp) { return value }
    return try connection.firstRow("SELECT CAST(strftime('%s', ?1) AS INTEGER) * 1000 + CAST(substr(?1 || '.000', 21, 3) AS INTEGER)", bindings: [.text(timestamp)])?.integer(0) ?? 0
}

/// `views/messages/_message:<template digest>/messages/<id>-<updated_at µs>/presentation-v3`;
/// the template digest is fixed for the process, so the message and its version identify it.
struct MessageFragmentKey: Hashable, Sendable {
    let messageID: Int64
    let updatedAtMicroseconds: Int64
    /// The bytes the Rails cache key would take, for the cache's byte budget.
    var byteCount: Int { 64 + String(messageID).utf8.count + String(updatedAtMicroseconds).utf8.count }
}

func messageFragmentKey(_ message: MessageVersion) -> MessageFragmentKey {
    MessageFragmentKey(messageID: message.id, updatedAtMicroseconds: timestampMicroseconds(message.updatedAt))
}

private let roomAssetPaths = BoundedCache<String, String>(limit: 4_096)

func roomAsset(_ logicalName: String) -> String {
    if let exact = AssetManifest.assets[logicalName] { return exact }
    if let cached = roomAssetPaths.value(for: logicalName) { return cached }
    let path = resolveRoomAsset(logicalName)
    roomAssetPaths.insert(path, for: logicalName)
    return path
}

private func resolveRoomAsset(_ logicalName: String) -> String {
    let basename = URL(fileURLWithPath: logicalName).lastPathComponent
    guard let asset = AssetManifest.assets[basename], logicalName.contains("/") else {
        return "/assets/\(logicalName)"
    }
    return asset.replacingOccurrences(of: "/assets/", with: "/assets/\(logicalName.dropLast(basename.count))")
}


func isoTimestamp(_ value: String) -> String {
    let normalized = value.replacingOccurrences(of: " ", with: "T")
    return normalized.hasSuffix("Z") ? normalized : normalized + "Z"
}

func timestampMicroseconds(_ value: String) -> Int64 {
    SQLiteTimestampCache.shared.microseconds(value)
}

func render(message: RoomMessage) -> String {
    let avatar = AvatarTokens.path(userID: message.creatorID, updatedAt: message.creatorUpdatedAt)
    let safeBody = AppSecrets.actionText.render(message.body)
    let escapedCreator = erbEscape(message.creatorName)
    let escapedTitle = erbEscape(message.creatorTitle)
    let escapedRoom = erbEscape(message.roomName)
    let messageID = "message_\(message.clientMessageID)"
    let editFrameID = "edit_message_\(message.clientMessageID)"
    let boostingFrameID = "boosting_message_\(message.clientMessageID)"
    let boostsID = "boosts_message_\(message.clientMessageID)"
    let newBoostFrameID = "new_boost_message_\(message.clientMessageID)"
    let boosts = message.boosts.map(renderBoost).joined()
    return "<div id=\"\(messageID)\" class=\"message \" data-controller=\"reply\" data-user-id=\"\(message.creatorID)\" data-message-id=\"\(message.id)\" data-message-timestamp=\"\(message.createdAtMilliseconds)\" data-message-updated-at=\"\(timestampMicroseconds(message.updatedAt) / 1000)\" data-sort-value=\"\(message.createdAtMilliseconds)\" data-messages-target=\"message\" data-search-results-target=\"message\" data-refresh-room-target=\"message\" data-reply-composer-outlet=\"#composer\"><h2 class=\"message__day-separator\"><time datetime=\"\(isoTimestamp(message.createdAt))\" data-local-time-target=\"date\"></time></h2><figure class=\"avatar message__avatar\"><a title=\"\(escapedTitle)\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"/users/\(message.creatorID)\"><img aria-hidden=\"true\" src=\"\(avatar)\" width=\"48\" height=\"48\"></a></figure><turbo-frame id=\"\(editFrameID)\"><div class=\"message__body\"><div class=\"message__body-content\"><div class=\"message__meta\"><h3 class=\"message__heading\"><span class=\"message__author\" title=\"\(escapedTitle)\"><strong data-reply-target=\"author\">\(escapedCreator)</strong></span><a target=\"_top\" class=\"message__permalink\" href=\"/rooms/\(message.roomID)/@\(message.id)\"><time class=\"message__timestamp\" datetime=\"\(isoTimestamp(message.createdAt))\" data-local-time-target=\"time\"></time></a><span class=\"message__room\"><a target=\"_top\" data-reply-target=\"link\" href=\"/rooms/\(message.roomID)/@\(message.id)\">\(escapedRoom)</a></span></h3>\(renderMessageActions(messageID: messageID, dbID: message.id, roomID: message.roomID))</div><div id=\"presentation_message_\(message.clientMessageID)\" dir=\"auto\" data-reply-target=\"body\" data-messages-target=\"body\">\(safeBody)</div><turbo-frame id=\"\(boostingFrameID)\"><div class=\"boosts flex flex-wrap align-center gap full-width\" style=\"--column-gap: 0.4ch; --row-gap: 0\" data-controller=\"turbo-streaming\" data-action=\"turbo:submit-start-&gt;turbo-streaming#unsubscribe\"><div class=\"flex-inline flex-wrap gap\" id=\"\(boostsID)\" data-turbo-streaming-target=\"container\">\(boosts)</div><turbo-frame id=\"\(newBoostFrameID)\"><div class=\"flex-inline message__boost-inline\" data-controller=\"soft-keyboard\"><a class=\"boost__action txt-small btn\" action=\"soft-keyboard#open\" href=\"/messages/\(message.id)/boosts/new\"><img aria-hidden=\"true\" src=\"\(roomAsset("boost.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Add a boost</span></a></div></turbo-frame></div></turbo-frame></div></div></turbo-frame></div>"
}

private func renderBoost(_ boost: RoomBoost) -> String {
    let avatar = AvatarTokens.path(userID: boost.creatorID, updatedAt: boost.creatorUpdatedAt)
    let title = erbEscape(boost.creatorTitle)
    let content = erbEscape(boost.content)
    let textClass = boost.content.unicodeScalars.allSatisfy { $0.properties.isEmoji } ? "txt-small txt-medium" : "txt-small"
    return "<div id=\"boost_\(boost.id)\" class=\"boost boost-item flex-inline postion--relative max-width align-center fill-white gap\" data-controller=\"boost-delete\" data-boost-delete-perform-class=\"boost--deleting\" data-boost-delete-reveal-class=\"expanded\" data-boost-delete-booster-id-value=\"\(boost.creatorID)\"><figure class=\"avatar boost__avatar flex-item-no-shrink\"><a title=\"\(title)\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"/users/\(boost.creatorID)\"><img aria-label=\"\(title) boosted \(content)\" src=\"\(avatar)\" width=\"48\" height=\"48\" /></a></figure><span role=\"button\" class=\"\(textClass)\" data-action=\"click-&gt;boost-delete#reveal keydown.enter-&gt;boost-delete#reveal:prevent\" data-boost-delete-target=\"content\">\(content)</span><form class=\"button_to\" method=\"post\" action=\"/messages/\(boost.messageID)/boosts/\(boost.id)\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button data-action=\"boost-delete#perform\" data-boost-delete-target=\"button\" class=\"btn btn--negative flex-item-justify-end boost__delete\" type=\"submit\"><img aria-hidden=\"true\" src=\"\(roomAsset("minus.svg"))\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Delete this boost</span></button></form></div><span id=\"delete_boost_accessible_label\" class=\"for-screen-reader\">Press enter to delete this boost</span>"
}

private func writeMessageArea(into buffer: inout RenderBuffer, roomID: Int64, roomKind: String, welcomeHTML: String?, fragments: [MessageFragment], loadedAt: Int64, streamName: String, origin: String, user: SignedInUser) {
    let userAvatar = AvatarTokens.path(userID: user.id, updatedAt: user.updatedAt)
    let template = """
    <script type="text/template" data-messages-target="template">
      <div class="message message--me $messageClasses$"
          id="message_$clientMessageId$"
          data-format-message-target="message"
          data-user-id="\(user.id)"
          data-message-timestamp="$messageTimestamp$"
          data-messages-target="message">
        <div class="message__day-separator"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="date"></time></div>

        <figure class="avatar message__avatar">
          <a title="\(erbEscape(user.name))" class="btn avatar" data-turbo-frame="_top" href="/users/\(user.id)"><img aria-hidden="true" src="\(userAvatar)" width="48" height="48" /></a>
        </figure>

        <div class="message__body">
          <div class="message__body-content">
            <div class="message__meta">
              <h3 class="message__heading">
                <span class="message__author"><strong>\(erbEscape(user.name))</strong></span>
                <span class="message__permalink"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="time"></time></span>
              </h3>
              <div class="message__actions">
                <div class="position-relative">
                  <span class="btn message__action-btn message__options-btn">
                    <img class="colorize--black" aria-hidden="true" src="\(roomAsset("menu-dots-horizontal.svg"))" />
                    <span class="for-screen-reader">Message options</span>
                  </span>
                </div class="position-relative">
              </div>
            </div>
            $body$
          </div>
        </div>
      </div>
    </script>
    """
    buffer.write("<div id=\"message-area\" class=\"message-area\" contents=\"true\" data-controller=\"messages presence drop-target\" data-action=\"turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged\" data-messages-first-of-day-class=\"message--first-of-day\" data-messages-formatted-class=\"message--formatted\" data-messages-me-class=\"message--me\" data-messages-mentioned-class=\"message--mentioned\" data-messages-threaded-class=\"message--threaded\" data-messages-page-url-value=\"\(origin)/rooms/\(roomID)/messages\">\(template)<div id=\"messages_\(roomKind)_\(roomID)\" class=\"messages\" data-controller=\"maintain-scroll refresh-room\" data-action=\"turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online\" data-messages-target=\"messages\" data-refresh-room-loaded-at-value=\"\(loadedAt)\" data-refresh-room-url-value=\"\(origin)/rooms/\(roomID)/refresh\">")
    if let welcomeHTML { buffer.write(welcomeHTML) }
    for fragment in fragments { buffer.write(fragment) }
    buffer.write("</div><turbo-cable-stream-source channel=\"RoomMessagesChannel\" signed-stream-name=\"\(streamName)\"></turbo-cable-stream-source><button class=\"message-area__return-to-latest btn\" data-action=\"messages#returnToLatest\" data-messages-target=\"latest\" hidden=\"hidden\"><img aria-hidden=\"true\" src=\"\(roomAsset("arrow-down.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Jump to newest message</span></button></div>")
}

private func renderNotificationDialog(origin: String) -> String {
    "<dialog class=\"dialog pad center center-block border-radius border shadow\" data-notifications-target=\"notAllowedNotice\" style=\"--inline-space: var(--block-space)\"><div class=\"flex flex-column txt-align-center\"><span class=\"btn btn--faux center txt-x-large\"><img aria-hidden=\"true\" src=\"\(roomAsset("notification-bell-alert.svg"))\" width=\"48\" height=\"48\"><span class=\"for-screen-reader\">Notifications alert</span></span><section><h1 class=\"txt-large margin-none\">Notifications aren’t allowed</h1><div class=\"txt-align-start margin-block-start\"><details class=\"notifications-help\" data-notifications-target=\"details\"><summary class=\"btn\"><img aria-hidden=\"true\" src=\"\(roomAsset("external/web.svg"))\" width=\"20\" height=\"20\"><strong>Check your Mozilla settings</strong><img aria-hidden=\"true\" class=\"disclosure\" src=\"\(roomAsset("disclosure.svg"))\" width=\"10\" height=\"10\"></summary><p>Ensure notifications are enabled for <em>\(origin)/</em> in your web browser settings.</p></details><details class=\"notifications-help hide-in-browser\" data-notifications-target=\"details\"><summary class=\"btn\"><img aria-hidden=\"true\" src=\"\(roomAsset("external/gear.svg"))\" width=\"20\" height=\"20\"><strong>Check your settings</strong><img aria-hidden=\"true\" class=\"disclosure\" src=\"\(roomAsset("disclosure.svg"))\" width=\"10\" height=\"10\"></summary><p>Ensure notifications are allowed for Mozilla in your system settings.</p></details><details class=\"notifications-help pwa__instructions hide-in-pwa\" data-controller=\"pwa-install\" data-notifications-target=\"details\" data-pwa-install-prompting-class=\"pwa--can-install\"><summary class=\"btn\"><img aria-hidden=\"true\" src=\"\(roomAsset("external/install.svg"))\" width=\"20\" height=\"20\"><strong>Install Campfire as a web app.</strong><img aria-hidden=\"true\" class=\"disclosure\" src=\"\(roomAsset("disclosure.svg"))\" width=\"10\" height=\"10\"></summary><p>Some platforms require you to install Campfire as a web app to receive push notifications.</p><div class=\"margin-block-start txt-align-center pwa__installer\"><hr class=\"separator margin-block\"><button class=\"btn btn--reversed center\" data-action=\"pwa-install#promptInstall\"><img aria-hidden=\"true\" src=\"\(roomAsset("external/install.svg"))\">Install now</button></div></details></div></section><form class=\"flex align-center gap center\" method=\"dialog\"><button autofocus=\"true\" class=\"btn dialog__close\"><span class=\"for-screen-reader\">Close</span><img aria-hidden=\"true\" src=\"\(roomAsset("remove.svg"))\" width=\"20\" height=\"20\"></button></form></div></dialog>"
}

private func renderMessageActions(messageID: String, dbID: Int64, roomID: Int64) -> String {
    let reactions = [("👍", "Thumbs up"), ("👏", "Clapping"), ("👋", "Waving hand"), ("💪", "Muscle"), ("❤️", "Red heart"), ("😂", "Face with tears of joy"), ("🎉", "Party popper"), ("🔥", "Fire")].map { emoji, title in
        "<form data-turbo-frame=\"boosting_\(messageID)\" data-action=\"popup#close\" accept-charset=\"UTF-8\" action=\"/messages/\(dbID)/boosts\" method=\"post\"><input type=\"hidden\" id=\"boost_content\" name=\"boost[content]\" value=\"\(emoji)\"><button name=\"button\" type=\"submit\" title=\"\(title)\" class=\"btn message__action-btn\" data-emoji=\"\(emoji)\"><figure class=\"margin-none boost-character\">\(emoji)</figure><span class=\"for-screen-reader\">\(title)</span></button></form>"
    }.joined()
    let numericID = String(dbID)
    return "<div class=\"message__actions\" data-controller=\"soft-keyboard\"><details class=\"position-relative\" data-controller=\"popup\" data-action=\"keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside\" data-popup-orientation-top-class=\"popup-orientation-top\"><summary class=\"btn message__action-btn message__options-btn\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("menu-dots-horizontal.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Message options</span></summary><div class=\"message__actions-menu border shadow\" data-popup-target=\"menu\"><div class=\"quick-boosts\">\(reactions)<a class=\"btn message__action-btn message__boost-btn\" data-turbo-frame=\"new_boost_\(messageID)\" data-action=\"soft-keyboard#open popup#close\" href=\"/messages/\(numericID)/boosts/new\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("boost.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">New boost</span></a></div><div class=\"flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid\"><button class=\"btn message__action-btn center full-width\" data-action=\"reply#reply\" title=\"Reply\" aria-label=\"Reply\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("reply.svg"))\" width=\"20\" height=\"20\"></button><button class=\"btn message__action-btn center full-width\" title=\"Copy link\" aria-label=\"Copy link\" data-controller=\"copy-to-clipboard\" data-action=\"copy-to-clipboard#copy\" data-copy-to-clipboard-success-class=\"btn--success\" data-copy-to-clipboard-url-value=\"/rooms/\(roomID)/@\(numericID)\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("link.svg"))\" width=\"20\" height=\"20\"></button><a class=\"btn message__action-btn center full-width message__edit-btn\" data-turbo-frame=\"edit_\(messageID)\" title=\"Edit\" aria-label=\"Edit\" href=\"/rooms/\(roomID)/messages/\(numericID)/edit\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("pencil.svg"))\" width=\"20\" height=\"20\"></a></div></div></details></div>"
}

private func renderComposer(roomID: Int64, origin: String) -> String {
    "<div class=\"composer flex align-end gap position-relative\" data-controller=\"typing-notifications\" data-typing-notifications-active-class=\"typing-indicator--active\"><a class=\"btn flex-item-no-shrink margin-block-end composer__context-btn\" style=\"view-transition-name: input-switcher\" href=\"/searches\"><img aria-hidden=\"true\" src=\"\(roomAsset("search.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Search</span></a><turbo-frame id=\"composer-frame\"><form id=\"composer\" class=\"margin-block flex-item-grow contain\" data-controller=\"composer drop-target\" data-action=\"dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop drop-target:drop@window-&gt;composer#dropFiles lexxy:file-accept-&gt;composer#preventAttachment refresh-room:online@window-&gt;composer#online typing-notifications#stop paste-&gt;composer#pasteFiles turbo:submit-end-&gt;composer#submitEnd refresh-room:offline@window-&gt;composer#offline\" data-composer-messages-outlet=\"#message-area\" data-composer-toolbar-class=\"composer--rich-text\" data-composer-room-id-value=\"\(roomID)\" action=\"/rooms/\(roomID)/messages\" accept-charset=\"UTF-8\" method=\"post\"><fieldset data-composer-target=\"fields\" contents><div class=\"flex flex-column\"><div class=\"composer__filelist flex flex--align-center gap flex-wrap\" data-composer-target=\"fileList\"></div><div class=\"flex composer__input input input--actor fill-white min-width\" style=\"--input-border-radius: 1.3rem\"><div class=\"flex align-end gap full-width\"><img aria-hidden=\"true\" class=\"composer__input-hint colorize--black\" style=\"view-transition-name: input-btn;\" src=\"\(roomAsset("messages-outlined.svg"))\" width=\"22\" height=\"22\"><div class=\"flex flex-column flex-item-grow min-width gap\"><lexxy-editor rows=\"1\" class=\"input lexxy-content\" style=\"order: -1\" aria-multiline=\"true\" aria-label=\"Write a message\" permitted-attachment-types=\"application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed\" data-controller=\"unfurl\" data-action=\"lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft lexxy:insert-link-&gt;unfurl#unfurl\" data-composer-target=\"text\" data-direct-upload-url=\"\(origin)/rails/active_storage/direct_uploads\" data-blob-url-template=\"\(origin)/rails/active_storage/blobs/redirect/:signed_id/:filename\" id=\"message_body\" input=\"message_body_trix_input_message\" name=\"message[body]\"><lexxy-prompt trigger=\"@\" name=\"mention\" src=\"/autocompletable/users?room_id=\(roomID)\" remote-filtering=\"true\" empty-results=\"No matches\"></lexxy-prompt></lexxy-editor></div><label class=\"btn btn--borderless txt-small flex-item-no-shrink composer__attachment-btn input--file\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("attachment.svg"))\" width=\"22\" height=\"22\"><input type=\"file\" data-action=\"composer#filePicked\" multiple><span class=\"for-screen-reader\">Attach a file</span></label><button class=\"btn btn--borderless txt-small flex-item-no-shrink composer__rich-text-btn\" type=\"button\" data-action=\"composer#toggleToolbar\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"\(roomAsset("text-options.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Rich text</span></button><button name=\"send\" type=\"submit\" data-action=\"composer#submit\" class=\"btn btn--reversed flex-item-no-shrink txt-small\"><img aria-hidden=\"true\" src=\"\(roomAsset("arrow-up.svg"))\" width=\"20\" height=\"20\"><span class=\"for-screen-reader\">Send Message</span></button></div></div></div></fieldset><div class=\"typing-indicator gap txt-small align-center flex-inline\" data-typing-notifications-target=\"indicator\"><div class=\"typing-indicator__author spinner\" data-typing-notifications-target=\"author\"></div></div><input data-composer-target=\"clientid\" type=\"hidden\" name=\"message[client_message_id]\" id=\"message_client_message_id\"></form></turbo-frame></div>"
}

private func lastRoomCookie(request: Request, roomID: Int64) -> String? {
    let current = RequestCookies.trimmedItemValue("last_room", in: request.headers[.cookie])
    guard current != String(roomID) else { return nil }
    return "last_room=\(roomID); path=/; expires=\(UTCTime.httpDate(UTCTime.twentyYearsFromNow())); samesite=lax"
}
