import Foundation
import Crypto
import NIOCore

/// A small UTF-8 writer used by typed renderers. Its next allocation follows the last render size.
public struct RenderBuffer {
    private var bytes: [UInt8]

    public init() {
        bytes = []; bytes.reserveCapacity(RenderCapacity.shared.read())
    }

    public mutating func write(_ string: String) { bytes.append(contentsOf: string.utf8) }
    public var utf8: [UInt8] { bytes }
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    public mutating func finish() -> String {
        RenderCapacity.shared.update(max(1_024, bytes.count))
        return string
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
    static func render(user: SignedInUser, account: SidebarAccount, lastRoomID: Int64?, shared: [SidebarRoom], directs: [SidebarDirect], placeholders: [SidebarUser], flash: RailsFlash) -> String {
        var buffer = RenderBuffer()
        buffer.write("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"\(AssetManifest.stylesheetPath)\" data-turbo-track=\"reload\"></head><body>")
        let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
        let streamSigner = RailsTurboStreamSigner(secretKeyBase: secret)
        let userGID = Data("gid://campfire/User/\(user.id)".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let roomStream = streamSigner.sign("rooms")
        let userRoomStream = streamSigner.sign("\(userGID):rooms")
        buffer.write("<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"\(roomStream)\"></turbo-cable-stream-source><turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"\(userRoomStream)\"></turbo-cable-stream-source>")
        buffer.write("<turbo-frame id=\"user_sidebar\"><nav class=\"sidebar\" data-last-room=\"\(lastRoomID ?? 0)\"><a class=\"account\">\(erbEscape(account.name))</a>")
        buffer.write("<div class=\"current-user\">\(erbEscape(user.name))</div>")
        if let notice = flash.notice { buffer.write("<div class=\"flash flash--notice\">\(erbEscape(notice))</div>") }
        if let alert = flash.alert { buffer.write("<div class=\"flash flash--alert\">\(erbEscape(alert))</div>") }
        buffer.write("<section class=\"sidebar__rooms\">")
        for room in shared {
            buffer.write("<a class=\"sidebar__room\(room.unread ? " unread" : "")\" href=\"/rooms/\(room.id)\">\(erbEscape(room.name))</a>")
        }
        buffer.write("</section><section class=\"sidebar__directs\">")
        for direct in directs {
            let display = direct.members.map(\.name).joined(separator: ", ")
            buffer.write("<a class=\"sidebar__direct\(direct.unread ? " unread" : "")\" href=\"/rooms/\(direct.id)\">\(erbEscape(display))</a>")
        }
        buffer.write("</section><div class=\"sidebar__direct-placeholders\" hidden>")
        for placeholder in placeholders { buffer.write("<span data-user-id=\"\(placeholder.id)\">\(erbEscape(placeholder.name))</span>") }
        buffer.write("</div></nav></turbo-frame></body></html>")
        return buffer.finish()
    }
}

func etag(for body: String) -> String {
    let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\"\(digest)\""
}
