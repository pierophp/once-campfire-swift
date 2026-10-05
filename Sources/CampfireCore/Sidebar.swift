import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

struct SidebarAccount: Sendable { let name: String }
struct SidebarRoom: Sendable { let id: Int64; let name: String; let unread: Bool }
struct SidebarUser: Sendable { let id: Int64; let name: String }
struct SidebarDirect: Sendable { let id: Int64; let unread: Bool; let updatedAt: String; let members: [SidebarUser] }
struct SidebarLayout: Sendable {
    let account: SidebarAccount
    let logoBlobID: Int64?
    let lastRoomID: Int64?

    static func load(request: Request, user: SignedInUser, database: SQLiteDatabase) async throws -> SidebarLayout {
        let lastRoomCookie = cookieInteger("last_room", request.headers[.cookie])
        return try await Task.detached {
            try database.read { connection in
                let account = try connection.firstRow("SELECT a.id, a.name, (SELECT b.id FROM active_storage_attachments x INNER JOIN active_storage_blobs b ON b.id=x.blob_id WHERE x.record_type='Account' AND x.record_id=a.id AND x.name='logo' LIMIT 1) FROM accounts a ORDER BY a.id ASC LIMIT 1")
                let roomID: Int64?
                if let lastRoomCookie {
                    roomID = try connection.firstRow("SELECT r.id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=? LIMIT 1", bindings: [.integer(lastRoomCookie), .integer(user.id)])?.integer(0)
                } else { roomID = nil }
                return SidebarLayout(account: SidebarAccount(name: account?.string(1) ?? "Campfire"), logoBlobID: account?.integer(2), lastRoomID: roomID)
            }
        }.value
    }
}
struct SidebarData: Sendable {
    let shared: [SidebarRoom]
    let directs: [SidebarDirect]
    let placeholders: [SidebarUser]
}

func installSidebarRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase) {
    router.get("/users/me/sidebar") { request, _ async throws -> Response in
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }

        let layout = try await SidebarLayout.load(request: request, user: session.user, database: database)
        let data = try await Task.detached {
            try database.read { connection -> SidebarData in
                let memberships = try connection.rows("SELECT m.id, m.room_id, m.unread_at, m.updated_at, r.name, r.type, r.updated_at FROM memberships m INNER JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND m.involvement!='invisible' ORDER BY LOWER(r.name)", bindings: [.integer(session.user.id)])
                var shared: [SidebarRoom] = []
                var directs: [SidebarDirect] = []
                for row in memberships {
                    guard let roomID = row.integer(1), let type = row.string(5) else { continue }
                    let unread = row.string(2) != nil
                    if type == "Rooms::Direct" {
                        let users = try connection.rows("SELECT u.id, u.name FROM memberships m INNER JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id!=? AND u.status=0 ORDER BY m.id", bindings: [.integer(roomID), .integer(session.user.id)])
                        let members = users.compactMap { row -> SidebarUser? in guard let id = row.integer(0), let name = row.string(1) else { return nil }; return SidebarUser(id: id, name: name) }
                        let fallback = members.isEmpty ? [SidebarUser(id: session.user.id, name: session.user.name)] : members
                        directs.append(SidebarDirect(id: roomID, unread: unread, updatedAt: row.string(6) ?? "", members: fallback))
                    } else {
                        shared.append(SidebarRoom(id: roomID, name: row.string(4) ?? "", unread: unread))
                    }
                }
                directs.sort { $0.updatedAt > $1.updatedAt }
                let placeholderRows = try connection.rows("SELECT u.id, u.name FROM users u WHERE u.status=0 AND u.id!=? AND u.id NOT IN (SELECT m.user_id FROM memberships m INNER JOIN rooms r ON r.id=m.room_id WHERE r.type='Rooms::Direct') ORDER BY u.created_at ASC LIMIT 20", bindings: [.integer(session.user.id)])
                let placeholders = placeholderRows.compactMap { row -> SidebarUser? in guard let id = row.integer(0), let name = row.string(1) else { return nil }; return SidebarUser(id: id, name: name) }
                return SidebarData(shared: shared, directs: directs, placeholders: placeholders)
            }
        }.value

        let flash = SessionPipeline.readFlash(request)
        let html = SidebarRenderer.render(user: session.user, account: layout.account, lastRoomID: layout.lastRoomID, shared: data.shared, directs: data.directs, placeholders: data.placeholders, flash: flash)
        let tag = etag(for: html)
        var response: Response
        if request.headers[HTTPField.Name("if-none-match")!] == tag {
            response = Response(status: .notModified)
        } else {
            response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: html)))
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

private func cookieInteger(_ name: String, _ header: String?) -> Int64? {
    guard let header else { return nil }
    for item in header.split(separator: ";") {
        let pair = item.split(separator: "=", maxSplits: 1)
        if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name { return Int64(pair[1]) }
    }
    return nil
}
