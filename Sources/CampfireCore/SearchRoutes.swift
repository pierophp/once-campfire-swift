import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

private struct SearchPageData: Sendable {
    let query: String?
    let messages: [SearchResultMessage]
    let recentSearches: [String]
    let returnToRoomID: Int64
}

private struct SearchResultMessage: Sendable {
    let version: MessageVersion
    let roomID: Int64
    let roomName: String
}

func installSearchRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase, fragmentCache: MessageFragmentCache) {
    router.get("/searches") { request, _ async throws -> Response in
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .found)
            response.headers[.location] = "/session/new"
            return response
        }

        let rawQuery = request.uri.queryParameters["q"].map(String.init)
        let query = rawQuery.map(sanitizeSearchQuery)
        let searchableTerms = query.map(ftsLiteralTerms).flatMap { $0.isEmpty ? nil : $0 }
        let cookieRoomID = searchCookieInteger("last_room", request.headers[.cookie])
        let lastRoomCookie = SidebarLayout.lastRoomCookie(request)
        let (data, messageFragments, layout) = try await database.readAsync { connection -> (SearchPageData, [MessageFragment], SidebarLayout) in
            let messages: [SearchResultMessage]
            if let searchableTerms, !searchableTerms.isEmpty {
                let rows = try connection.rows("SELECT m.id, m.created_at, m.updated_at, CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4, 3) AS INTEGER), r.id, r.name FROM messages m INNER JOIN rooms r ON r.id=m.room_id INNER JOIN memberships membership ON membership.room_id=r.id INNER JOIN message_search_index idx ON idx.rowid=m.id WHERE membership.user_id=? AND idx.body MATCH ? ORDER BY m.created_at DESC LIMIT 100", bindings: [.integer(session.user.id), .text(searchableTerms)])
                messages = rows.compactMap { row -> SearchResultMessage? in
                    guard let id = row.integer(0), let createdAt = row.string(1), let updatedAt = row.string(2), let roomID = row.integer(4) else { return nil }
                    return SearchResultMessage(version: MessageVersion(id: id, createdAt: createdAt, updatedAt: updatedAt, createdAtMilliseconds: row.integer(3) ?? 0), roomID: roomID, roomName: row.string(5) ?? "")
                }.reversed()
            } else {
                messages = []
            }
            let recents = try connection.rows("SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC", bindings: [.integer(session.user.id)]).compactMap { $0.string(0) }
            let returnToRoom = try connection.firstRow("SELECT r.id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND r.id=? LIMIT 1", bindings: [.integer(session.user.id), .integer(cookieRoomID ?? 0)])?.integer(0)
                ?? connection.firstRow("SELECT r.id FROM rooms r INNER JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.created_at ASC LIMIT 1", bindings: [.integer(session.user.id)])?.integer(0)
                ?? 0
            let data = SearchPageData(query: query.flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil }, messages: messages, recentSearches: recents, returnToRoomID: returnToRoom)
            let fragments = try CampfireCore.messageFragments(connection, versions: messages.map(\.version), fragmentCache: fragmentCache) { index in (messages[index].roomName, messages[index].roomID) }
            let layout = try SidebarLayout.load(connection: connection, lastRoomCookie: lastRoomCookie, user: session.user)
            return (data, fragments, layout)
        }

        let queryNav: String
        if let query = data.query {
            queryNav = "<div class=\"searches__query flex align-center gap pad-block-start-half\"><div class=\"btn btn--reversed btn--faux align-center gap txt-nowrap\"><span class=\"overflow-ellipsis\">“\(erbEscape(query))”</span><span class=\"flex-item-no-shrink\">\(data.messages.count)</span></div></div>"
        } else { queryNav = "" }
        let origin = "http://\(request.head.authority ?? "localhost")"
        let recents = renderRecentSearches(data.recentSearches, origin: origin)
        let pageNav = queryNav + "<div class=\"searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar\">\(recents)</div>"
        let sidebar = "<div class=\"rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar\">\(recents)</div>"
        let pageContentPrefix = "<div id=\"message-area\" class=\"message-area\"><div class=\"message-area--empty min-width center\"><figure class=\"center pad\"><img aria-hidden=\"true\" class=\"colorize--black translucent\" src=\"\(roomAsset("search.svg"))\" /></figure></div><div id=\"search-results\" class=\"messages searches__results\" data-controller=\"search-results\" data-search-results-target=\"messages\" data-search-results-me-class=\"message--me\" data-search-results-threaded-class=\"message--threaded\" data-search-results-mentioned-class=\"message--mentioned\" data-search-results-formatted-class=\"message--formatted\">"
        let pageFooter = "<div class=\"composer flex align-end gap\"><a class=\"btn flex-item-no-shrink margin-block-end\" style=\"view-transition-name: input-switcher; --btn-border-radius: 0.5em\" href=\"/rooms/\(data.returnToRoomID)\"><img aria-hidden=\"true\" src=\"\(roomAsset("arrow-left.svg"))\" /><span class=\"for-screen-reader\">Exit search </span></a><form class=\"margin-block flex-item-grow contain flex align-center gap\" data-controller=\"form\" data-action=\"keydown.esc-&gt;form#cancel\" action=\"/searches\" accept-charset=\"UTF-8\" method=\"post\"><div class=\"composer__input flex align-center flex-item-grow gap full-width input input--actor min-width\"><img aria-hidden=\"true\" class=\"composer__input-hint colorize--black\" style=\"view-transition-name: input-btn;\" src=\"\(roomAsset("search.svg"))\" width=\"20\" height=\"20\" /><input\(rawQuery.map { " value=\"\(erbEscape($0))\"" } ?? "") class=\"searches__input input flex-item-grow\" role=\"searchbox\" aria-label=\"search\" autofocus=\"autofocus\" required=\"required\" type=\"text\" name=\"q\" id=\"q\" /><a data-form-target=\"cancel\" role=\"button\" class=\"searches__reset\" href=\"/searches\"><img aria-hidden=\"true\" class=\"colorize--black\" src=\"\(roomAsset("remove.svg"))\" width=\"14\" height=\"14\" /><span class=\"for-screen-reader\">Clear search field</span></a><button name=\"button\" type=\"submit\" class=\"btn btn--reversed flex-item-no-shrink txt-small\" style=\"--btn-border-radius: 0.5em\"><img aria-hidden=\"true\" src=\"\(roomAsset("arrow-up.svg"))\" /><span class=\"for-screen-reader\">Search</span></button></div></form></div>"
        let flash = SessionPipeline.readFlash(request)
        let body = SidebarRenderer.render(user: session.user, account: layout.account, lastRoomID: layout.lastRoomID, shared: [], directs: [], placeholders: [], canCreateRooms: false, flash: flash, pageTitle: "Search", pageNav: pageNav, pageContentWriter: { buffer in
            buffer.write(pageContentPrefix)
            for fragment in messageFragments { buffer.write(fragment) }
            buffer.write("</div></div>")
        }, pageFooter: pageFooter, pageBodyClass: "sidebar searches", pageSidebarContent: sidebar)
        var response = Response(status: .ok, body: body.responseBody())
        response.headers[.contentType] = "text/html; charset=utf-8"
        response.headers[HTTPField.Name("cache-control")!] = "max-age=0, private, must-revalidate"
        response.headers[HTTPField.Name("etag")!] = body.etag()
        SessionPipeline.appendRefreshCookie(session, to: &response)
        if let flashCookie = flash.setCookie { response.headers.append(HTTPField(name: .setCookie, value: flashCookie)) }
        return response
    }
}

private func sanitizeSearchQuery(_ query: String) -> String {
    String(String.UnicodeScalarView(query.unicodeScalars.map { scalar in
        isOnigmoWord(scalar) ? scalar : " "
    }))
}

private func isOnigmoWord(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .connectorPunctuation:
        return true
    case .format:
        return scalar.value == 0x200C || scalar.value == 0x200D
    default:
        return false
    }
}

private func ftsLiteralTerms(_ sanitizedQuery: String) -> String {
    sanitizedQuery.split(whereSeparator: { $0.isWhitespace || $0 == "\0" })
        .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        .joined(separator: " ")
}

private func renderRecentSearches(_ searches: [String], origin: String) -> String {
    var html = ""
    for search in searches {
        html += "<a class=\"align-center gap room btn txt-nowrap\" href=\"/searches?q=\(cgiEscape(search))\"><span class=\"overflow-ellipsis\">“\(erbEscape(search))”</span></a>"
    }
    if !searches.isEmpty {
        html += "<form class=\"button_to\" method=\"post\" action=\"\(origin)/searches/clear\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn searches__btn\" data-turbo-confirm=\"Are you sure you want to clear your recent searches?\" type=\"submit\"><img aria-hidden=\"true\" src=\"\(roomAsset("broom.svg"))\" /><span class=\"for-screen-reader\">Clear recent searches</span></button></form>"
    }
    return html
}

private func cgiEscape(_ value: String) -> String {
    value.utf8.map { byte -> String in
        if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(Int(byte)) { return String(UnicodeScalar(byte)) }
        if byte == 32 { return "+" }
        return String(format: "%%%02X", byte)
    }.joined()
}

private func searchCookieInteger(_ name: String, _ header: String?) -> Int64? { RequestCookies.integer(name, in: header) }
