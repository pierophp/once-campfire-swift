import Foundation
import Crypto
import NIOCore

/// A UTF-8 writer used by typed renderers. Text goes straight into ByteBuffers, so a page is
/// never re-validated as a String; cached message fragments are kept by reference (see
/// `RenderedPage`). Its initial capacity follows the last render size.
public struct RenderBuffer {
    private var run: ByteBuffer
    private var parts: [RenderedPage.Part] = []
    private var length = 0

    public init() {
        run = ByteBufferAllocator().buffer(capacity: RenderCapacity.shared.read())
    }

    public mutating func write(_ string: String) { run.writeString(string) }

    mutating func write(_ fragment: MessageFragment) {
        flushRun()
        parts.append(.fragment(fragment))
        length += fragment.byteCount
    }

    mutating func finish() -> RenderedPage {
        flushRun()
        RenderCapacity.shared.update(max(1_024, parts.reduce(0) { total, part in
            if case .text(let text) = part { return max(total, text.readableBytes) } else { return total }
        }))
        return RenderedPage(parts: parts, length: length)
    }

    private mutating func flushRun() {
        guard run.readableBytes > 0 else { return }
        length += run.readableBytes
        parts.append(.text(run))
        run = ByteBufferAllocator().buffer(capacity: 512)
    }
}

private final class RenderCapacity: @unchecked Sendable {
    static let shared = RenderCapacity()
    private let lock = NSLock()
    private var value = 4_096
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ capacity: Int) { lock.lock(); value = capacity; lock.unlock() }
}

enum SidebarRenderer {
    static func render(user: SignedInUser, account: SidebarAccount, lastRoomID: Int64?, shared: [SidebarRoom], directs: [SidebarDirect], placeholders: [SidebarUser], canCreateRooms: Bool, flash: RailsFlash, pageTitle: String = "Campfire", pageHead: String = "", pageNav: String = "", pageContent: String = "", pageContentWriter: ((inout RenderBuffer) -> Void)? = nil, pageFooter: String = "", pageBodyClass: String = "", lazySidebar: Bool = false, pageSidebarContent: String? = nil) -> RenderedPage {
        var buffer = RenderBuffer()
        let hasPageContent = pageContentWriter != nil || !pageContent.isEmpty
        func writePageContent(_ buffer: inout RenderBuffer) {
            if let pageContentWriter { pageContentWriter(&buffer) } else { buffer.write(pageContent) }
        }
        let logoURL = "/account/logo?v=\(account.logoVersion)"
        buffer.write("<!DOCTYPE html><html><head><title>\(erbEscape(pageTitle))</title>")
        buffer.write("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content\"><meta name=\"view-transition\" content=\"same-origin\"><meta name=\"color-scheme\" content=\"light dark\"><meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#000000\" media=\"(prefers-color-scheme: dark)\"><meta name=\"apple-mobile-web-app-capable\" content=\"yes\">")
        buffer.write("<meta name=\"current-user-id\" content=\"\(user.id)\"><meta name=\"current-user-name\" content=\"\(erbEscape(user.name))\"><meta name=\"action-cable-url\" content=\"/cable\"><meta name=\"vapid-public-key\"><meta name=\"turbo-prefetch\" content=\"true\"><link rel=\"manifest\" href=\"/webmanifest.json\"><link rel=\"icon\" href=\"\(logoURL)\" type=\"image/png\"><link rel=\"apple-touch-icon\" href=\"\(logoURL)\">")
        buffer.write(AssetManifest.stylesheetTags)
        if let styles = account.customStyles { buffer.write("<style data-turbo-track=\"reload\">\(styles)</style>") }
        buffer.write(AssetManifest.importmapTags)
        buffer.write(pageHead)
        let bodyClasses = ([pageBodyClass, user.role == 1 ? "admin" : ""].filter { !$0.isEmpty }).joined(separator: " ")
        buffer.write("</head><body class=\"\(bodyClasses)\" data-controller=\"local-time lightbox\"><a href=\"#main-content\" class=\"skip-navigation btn\">Skip to main content</a><nav id=\"nav\">\(pageNav)</nav>")
        if let notice = flash.notice ?? flash.alert {
            let alert = flash.alert != nil
            let icon = assetPath(alert ? "alert.svg" : "check.svg")
            let style = alert ? "--flash-background: var(--color-negative)" : ""
            buffer.write("<div class=\"flash\" data-controller=\"element-removal\" data-action=\"animationend->element-removal#remove\"><div class=\"flash__inner shadow\" style=\"\(style)\"><img aria-hidden=\"true\" class=\"colorize--white\" height=\"24\" src=\"\(icon)\" width=\"24\"></span></div><span class=\"for-screen-reader\" role=\"alert\" aria-atomic=\"true\">\(erbEscape(notice))</span></div>")
        }
        if let pageSidebarContent {
            buffer.write("<main id=\"main-content\">"); writePageContent(&buffer)
            buffer.write("<footer id=\"footer\">\(pageFooter)</footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\">\(pageSidebarContent)</aside>")
        } else if !hasPageContent {
            buffer.write("<main id=\"main-content\"><turbo-frame data-action=\"presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload\" data-controller=\"rooms-list read-rooms turbo-frame\" data-rooms-list-unread-class=\"unread\" data-turbo-permanent=\"true\" id=\"user_sidebar\" target=\"_top\">")
        } else if lazySidebar {
            buffer.write("<main id=\"main-content\">"); writePageContent(&buffer)
            buffer.write("<footer id=\"footer\">\(pageFooter)</footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\"><turbo-frame data-action=\"presence:present@window-&gt;rooms-list#read read-rooms:read-&gt;rooms-list#read turbo:frame-load-&gt;rooms-list#loaded refresh-room:visible@window-&gt;turbo-frame#reload\" data-controller=\"rooms-list read-rooms turbo-frame\" data-rooms-list-unread-class=\"unread\" data-turbo-permanent=\"true\" id=\"user_sidebar\" src=\"/users/me/sidebar\" target=\"_top\">")
        } else {
            buffer.write("<main id=\"main-content\">"); writePageContent(&buffer)
            buffer.write("<footer id=\"footer\">\(pageFooter)</footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\"><turbo-frame data-action=\"presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload\" data-controller=\"rooms-list read-rooms turbo-frame\" data-rooms-list-unread-class=\"unread\" data-turbo-permanent=\"true\" id=\"user_sidebar\" target=\"_top\">")
        }
        if pageSidebarContent == nil && !lazySidebar {
        let userGID = base64URL(Data("gid://campfire/User/\(user.id)".utf8).base64EncodedString(), padded: false)
        let roomStream = AppSecrets.turboStreamName("rooms")
        let userRoomStream = AppSecrets.turboStreamName("\(userGID):rooms")
        buffer.write("<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"\(roomStream)\"></turbo-cable-stream-source><turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"\(userRoomStream)\"></turbo-cable-stream-source>")
        buffer.write("<div class=\"sidebar__container overflow-y overflow-hide-scrollbar\" data-action=\"rooms-list:unread@window->badge-dot#update rooms-list:read@window->badge-dot#update turbo:submit-start->turbo-frame#unpermanize\" data-badge-dot-unread-class=\"unread\" data-controller=\"badge-dot\"><turbo-frame id=\"direct_rooms_control\" target=\"_top\"><div class=\"directs gap overflow-x overflow-hide-scrollbar\"><a class=\"direct direct__new\" data-turbo-frame=\"_self\" href=\"/rooms/directs/new\"><span class=\"avatar avatar--icon\"><img aria-hidden=\"true\" class=\"colorize--black\" height=\"20\" src=\"\(assetPath("messages-add.svg"))\" width=\"20\"></span><span class=\"direct__author flex max-width min-width border-radius pad-inline-half\"><span class=\"for-screen-reader\">New</span><span class=\"txt-small overflow-clip\">Ping</span></span></a><div id=\"direct_rooms\" contents data-action=\"rooms-list:unread@window->sorted-list#updateItem\" data-controller=\"sorted-list\">")
        for direct in directs { render(direct: direct, into: &buffer) }
        buffer.write("</div><div contents>")
        for placeholder in placeholders { render(placeholder: placeholder, into: &buffer) }
        buffer.write("</div></div></turbo-frame><div class=\"rooms position-relative flex flex-column gap\"><div id=\"shared_rooms\" contents data-controller=\"sorted-list\">")
        for room in shared { render(room: room, into: &buffer) }
        buffer.write("</div>")
        if canCreateRooms { buffer.write("<a aria-label=\"New Chat Room\" class=\"rooms__new-btn btn room align-center gap txt-reversed\" href=\"/rooms/opens/new\"><img aria-hidden=\"true\" height=\"20\" src=\"\(assetPath("add.svg"))\" style=\"view-transition-name: new-room\" width=\"20\"></a>") }
        buffer.write("</div><button class=\"btn sidebar__toggle\" data-action=\"toggle-class#toggle\"><img aria-hidden=\"true\" height=\"20\" src=\"\(assetPath("menu.svg"))\" width=\"20\"><span class=\"for-screen-reader\">Open menu</span></button></div><div class=\"flex align-end sidebar__tools gap justify-end\"><a class=\"btn avatar flex-item-no-shrink sidebar__tool\" href=\"/users/me/profile\"><img aria-hidden=\"true\" height=\"48\" src=\"\(avatarPath(user))\" style=\"view-transition-name: avatar-\(user.id)\" width=\"48\"><span class=\"for-screen-reader\">My Settings</span></a><a class=\"btn align-center gap txt-reversed sidebar__tool\" href=\"/account/edit\"><img aria-hidden=\"true\" height=\"20\" src=\"\(assetPath("settings.svg"))\" style=\"view-transition-name: account-settings\" width=\"20\"><span class=\"for-screen-reader\">Account Settings</span></a></div></turbo-frame>")
        if !hasPageContent {
            buffer.write("<footer id=\"footer\"></footer></main><aside id=\"sidebar\" data-controller=\"toggle-class\" data-toggle-class-toggle-class=\"open\"></aside>")
        } else if pageSidebarContent == nil {
            buffer.write("</aside>")
        }
        } else if pageSidebarContent == nil {
            buffer.write("</turbo-frame></aside>")
        }
        buffer.write("<dialog class=\"lightbox\" aria-label=\"Image Viewer (Press escape to close)\" data-lightbox-target=\"dialog\" data-action=\"close->lightbox#reset\"><img src=\"\" class=\"lightbox__image\" data-lightbox-target=\"zoomedImage\"><form method=\"dialog\" class=\"lightbox__btn\"><button class=\"btn\"><img aria-hidden=\"true\" src=\"\(assetPath("remove.svg"))\"><span class=\"for-screen-reader\">Close image viewer</span></button></form><a href=\"\" class=\"lightbox__btn--download btn hide-in-ios-pwa\" data-lightbox-target=\"download\"><img aria-hidden=\"true\" src=\"\(assetPath("download.svg"))\"><span class=\"for-screen-reader\">Download file</span></a><button class=\"lightbox__btn--share btn\" data-action=\"web-share#share\" data-controller=\"web-share\" data-lightbox-target=\"share\" data-web-share-files-value=\"\"><img aria-hidden=\"true\" src=\"\(assetPath("share.svg"))\"><span class=\"for-screen-reader\">Share file</span></button></dialog><a href=\"https://once.com\" id=\"app-logo\" target=\"_blank\" aria-label=\"Once software from 37signals home page\"><img alt=\"Campfire logo\" height=\"216\" src=\"\(assetPath("campfire-icon.png"))\" width=\"256\"></a></body></html>")
        return buffer.finish()
    }

    private static func assetPath(_ logical: String) -> String { AssetManifest.assets[logical] ?? "/assets/\(logical)" }

    private static func avatarPath(_ user: SignedInUser) -> String { AvatarTokens.path(userID: user.id, updatedAt: user.updatedAt) }

    private static func avatarPath(_ user: SidebarUser) -> String { AvatarTokens.path(userID: user.id, updatedAt: user.updatedAt) }

    private static func firstName(_ name: String) -> String { name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }

    private static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(3).compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    private static func render(direct: SidebarDirect, into buffer: inout RenderBuffer) {
        let unread = direct.unread ? " unread" : ""
        let members = direct.members
        let group = members.count > 1
        let first = members.first ?? SidebarUser(id: 0, name: "", updatedAt: "")
        buffer.write("<a class=\"direct\(unread)\" data-badge-dot-target=\"unread\" data-room-id=\"\(direct.id)\" data-rooms-list-target=\"room\" data-sorted-list-number=\"\(direct.updatedAt)\" data-sorted-list-target=\"item\" href=\"/rooms/\(direct.id)\" id=\"list_rooms_direct_\(direct.id)\">")
        if group {
            buffer.write("<div class=\"avatar__group\">")
            for member in members.prefix(4) { buffer.write("<span class=\"avatar\"><img aria-hidden=\"true\" height=\"20\" src=\"\(avatarPath(member))\" width=\"20\"></span>") }
            buffer.write("</div>")
        } else { buffer.write("<span class=\"avatar\"><img aria-hidden=\"true\" height=\"48\" src=\"\(avatarPath(first))\" width=\"48\"></span>") }
        let initials = members.map { initials($0.name) }
        let label: String
        if group, initials.count > 2 { label = initials.dropLast().joined(separator: ", ") + ", and " + (initials.last ?? "") }
        else if group { label = initials.joined(separator: "+") }
        else { label = firstName(first.name) }
        let pingWith = group ? "Ping with" : "Ping with"
        buffer.write("<span class=\"direct__author flex align-center gap max-width min-width border-radius txt-small\"><span class=\"txt-nowrap overflow-ellipsis\"><span class=\"for-screen-reader\">\(pingWith)</span>\(erbEscape(label))</span></span></a>")
    }

    private static func render(placeholder: SidebarUser, into buffer: inout RenderBuffer) {
        buffer.write("<form action=\"/rooms/directs?user_ids%5B%5D=\(placeholder.id)\" class=\"button_to\" method=\"post\"><button class=\"direct borderless fill-transparent unpad\" type=\"submit\"><span class=\"avatar\"><img aria-hidden=\"true\" src=\"\(avatarPath(placeholder))\"></span><span class=\"direct__author flex align-center gap max-width min-width border-radius txt-small\"><span class=\"txt-nowrap overflow-ellipsis\"><span class=\"for-screen-reader\">Start a ping with</span>\(erbEscape(firstName(placeholder.name)))</span></span></button></form>")
    }

    private static func render(room: SidebarRoom, into buffer: inout RenderBuffer) {
        let kind = room.type == "Rooms::Open" ? "rooms_open" : "rooms_closed"
        let className = room.unread ? "align-center gap room btn txt-nowrap unread" : "align-center gap room btn txt-nowrap"
        buffer.write("<a class=\"\(className)\" data-badge-dot-target=\"unread\" data-room-id=\"\(room.id)\" data-rooms-list-target=\"room\" data-sorted-list-name=\"\(erbEscape(room.name))\" data-sorted-list-target=\"item\" href=\"/rooms/\(room.id)\" id=\"list_\(kind)_\(room.id)\" style=\"--column-gap: 0.5em\"><span class=\"overflow-ellipsis\">\(erbEscape(room.name))</span></a>")
    }
}

func etag(for body: String) -> String {
    var body = body
    return body.withUTF8 { etag(forBytes: UnsafeRawBufferPointer($0)) }
}

func etag(for body: ByteBuffer) -> String {
    body.withUnsafeReadableBytes { etag(forBytes: $0) }
}

private func etag(forBytes bytes: UnsafeRawBufferPointer) -> String {
    let digest = hexEncoded(SHA256.hash(data: bytes).prefix(16))
    return "W/\"\(digest)\""
}
