import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

struct SidebarAccount: Sendable { let name: String; let logoVersion: String; let customStyles: String? }
struct SidebarRoom: Sendable { let id: Int64; let name: String; let type: String; let unread: Bool; let updatedAtEpoch: String }
struct SidebarUser: Sendable { let id: Int64; let name: String; let updatedAt: String }
struct SidebarDirect: Sendable { let id: Int64; let unread: Bool; let updatedAt: String; let members: [SidebarUser] }
struct SidebarLayout: Sendable {
    let account: SidebarAccount
    let lastRoomID: Int64?

    static func lastRoomCookie(_ request: Request) -> Int64? { cookieInteger("last_room", request.headers[.cookie]) }

    static func load(connection: SQLiteConnection, lastRoomCookie: Int64?, user: SignedInUser) throws -> SidebarLayout {
        let account = try connection.firstRow("SELECT a.id, a.name, strftime('%Y%m%d%H%M%S', a.updated_at), a.custom_styles, (SELECT b.id FROM active_storage_attachments x INNER JOIN active_storage_blobs b ON b.id=x.blob_id WHERE x.record_type='Account' AND x.record_id=a.id AND x.name='logo' LIMIT 1) FROM accounts a ORDER BY a.id ASC LIMIT 1")
        let roomID: Int64?
        if let lastRoomCookie {
            roomID = try connection.firstRow("SELECT r.id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(lastRoomCookie), .integer(user.id)])?.integer(0)
        } else { roomID = nil }
        return SidebarLayout(account: SidebarAccount(name: account?.string(1) ?? "Campfire", logoVersion: account?.string(2) ?? "", customStyles: account?.string(3)), lastRoomID: roomID)
    }
}
struct SidebarData: Sendable {
    let shared: [SidebarRoom]
    let directs: [SidebarDirect]
    let placeholders: [SidebarUser]
    let canCreateRooms: Bool
}

func installSidebarRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase, responseCache: ResponseCache) {
    router.get("/users/me/sidebar") { request, _ async throws -> Response in
        let round = responseCache.begin(request, endpoint: "users/sidebars#show")
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }
        let flash = SessionPipeline.readFlash(request)
        if let cached = responseCache.lookup(round, request: request, session: session, flash: flash) {
            var response = cached.response(notModified: cached.etag != nil && request.headers[HTTPField.Name("if-none-match")!] == cached.etag)
            SessionPipeline.appendRefreshCookie(session, to: &response)
            return response
        }

        let lastRoomCookie = SidebarLayout.lastRoomCookie(request)
        let (layout, data) = try await database.readAsync { connection -> (SidebarLayout, SidebarData) in
            let layout = try SidebarLayout.load(connection: connection, lastRoomCookie: lastRoomCookie, user: session.user)
            // Column 7 is the room's updated_at in epoch milliseconds, as JavaScript sorts it.
            let memberships = try connection.rows("SELECT m.id, m.room_id, m.unread_at, m.updated_at, r.name, r.type, r.updated_at, CASE WHEN typeof(r.updated_at)='text' THEN CAST(strftime('%s', r.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', r.updated_at), 4, 3) AS INTEGER) END FROM memberships m INNER JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND m.involvement!='invisible' ORDER BY LOWER(r.name)", bindings: [.integer(session.user.id)])
            var shared: [SidebarRoom] = []
            var directs: [SidebarDirect] = []
            for row in memberships {
                guard let roomID = row.integer(1), let type = row.string(5) else { continue }
                let unread = row.string(2) != nil
                if type == "Rooms::Direct" {
                    let users = try connection.rows("SELECT u.id, u.name, u.updated_at FROM memberships m INNER JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id!=? AND u.status=0", bindings: [.integer(roomID), .integer(session.user.id)])
                    let members = users.compactMap { row -> SidebarUser? in guard let id = row.integer(0), let name = row.string(1) else { return nil }; return SidebarUser(id: id, name: name, updatedAt: row.string(2) ?? "") }
                    let fallback = members.isEmpty ? [SidebarUser(id: session.user.id, name: session.user.name, updatedAt: session.user.updatedAt)] : members
                    let epoch = row.integer(7) ?? 0
                    directs.append(SidebarDirect(id: roomID, unread: unread, updatedAt: String(epoch), members: fallback))
                } else {
                    let epoch = row.integer(7) ?? 0
                    shared.append(SidebarRoom(id: roomID, name: row.string(4) ?? "", type: type, unread: unread, updatedAtEpoch: String(epoch)))
                }
            }
            directs.sort { $0.updatedAt > $1.updatedAt }
            let directUserIDs = try connection.rows("SELECT DISTINCT m.user_id FROM memberships m WHERE m.room_id IN (SELECT mine.room_id FROM memberships mine INNER JOIN rooms r ON r.id=mine.room_id WHERE mine.user_id=? AND r.type='Rooms::Direct')", bindings: [.integer(session.user.id)])
                .compactMap { $0.integer(0) }
            let excludedIDs = directUserIDs + [session.user.id]
            let placeholderLimit = max(20 - excludedIDs.count, 0)
            let placeholders = excludedIDs.map { _ in "?" }.joined(separator: ",")
            let placeholderRows = try connection.rows("SELECT u.id, u.name, u.updated_at FROM users u WHERE u.status=0 AND u.id NOT IN (\(placeholders)) ORDER BY u.created_at ASC LIMIT \(placeholderLimit)", bindings: excludedIDs.map(SQLiteValue.integer))
            let placeholderUsers = placeholderRows.compactMap { row -> SidebarUser? in guard let id = row.integer(0), let name = row.string(1) else { return nil }; return SidebarUser(id: id, name: name, updatedAt: row.string(2) ?? "") }
            let settings = try connection.firstRow("SELECT settings FROM accounts ORDER BY id ASC LIMIT 1")?.string(0)
            let restricted = settings.flatMap { data -> Bool? in guard let bytes = data.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }; return json["restrict_room_creation_to_administrators"] as? Bool } ?? false
            return (layout, SidebarData(shared: shared, directs: directs, placeholders: placeholderUsers, canCreateRooms: session.user.role == 1 || !restricted))
        }

        let html = SidebarRenderer.render(user: session.user, account: layout.account, lastRoomID: layout.lastRoomID, shared: data.shared, directs: data.directs, placeholders: data.placeholders, canCreateRooms: data.canCreateRooms, flash: flash)
        let tag = html.etag()
        var response: Response
        if request.headers[HTTPField.Name("if-none-match")!] == tag {
            response = Response(status: .notModified)
        } else {
            response = Response(status: .ok, body: html.responseBody())
            response.headers[.contentType] = "text/html; charset=utf-8"
        }
        response.headers[HTTPField.Name("etag")!] = tag
        response.headers[HTTPField.Name("cache-control")!] = "max-age=0, private, must-revalidate"
        SessionPipeline.appendRefreshCookie(session, to: &response)
        if let cookie = flash.setCookie {
            response.headers.append(HTTPField(name: HTTPField.Name("set-cookie")!, value: cookie))
        }
        return response
    }
}

private func cookieInteger(_ name: String, _ header: String?) -> Int64? { RequestCookies.integer(name, in: header) }
