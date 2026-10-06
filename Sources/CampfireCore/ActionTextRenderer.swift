import Foundation
import SwiftSoup

public struct ActionTextMentionUser: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let title: String
    public let attachableGlobalID: String
    public let path: String
    public let avatarPath: String

    public init(id: Int, name: String, title: String, attachableGlobalID: String, path: String, avatarPath: String) {
        self.id = id
        self.name = name
        self.title = title
        self.attachableGlobalID = attachableGlobalID
        self.path = path
        self.avatarPath = avatarPath
    }
}

public protocol ActionTextUserResolving: Sendable {
    func user(id: Int) -> ActionTextMentionUser?
}

/// Renders stored Action Text bodies for message HTML and plain-text consumers.
/// Parsing failures and unsupported nesting use the message partial's unrenderable fallback: empty output.
public struct ActionTextRenderer: Sendable {
    private let verifier: RailsSignedGlobalID?
    private let userResolver: (any ActionTextUserResolving)?
    private let now: @Sendable () -> String

    public init(
        secretKeyBase: String? = nil,
        userResolver: (any ActionTextUserResolving)? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.verifier = secretKeyBase.map(RailsSignedGlobalID.init(secretKeyBase:))
        self.userResolver = userResolver
        self.now = now
    }

    /// Rails Action Text's presentation fragment used inside a message partial.
    public func render(_ body: String) -> String {
        guard body.utf8.count < 1_000_000,
              nestingDepth(body) <= 400,
              body.components(separatedBy: "<").count < 100_000,
              !body.contains("<action-text-attachment") || body.contains(">") else { return "" }
        do {
            let document = try SwiftSoup.parseBodyFragment(body)
            try document.outputSettings().prettyPrint(pretty: false)
            guard let root = try document.body() else { return "" }
            let elements = try root.getAllElements().array()
            guard elements.count < 20_000,
                  (try elements.map({ try $0.parents().size() }).max() ?? 0) < 257 else { return "" }
            try expandAttachments(in: root)
            try autolink(root)
            try sanitize(root)
            let content = try root.html().replacingOccurrences(of: " />", with: ">")
            if content.replacingOccurrences(of: "<p></p>", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            return "<div class=\"lexxy-content\">\n  \(content)\n</div>\n"
        } catch {
            return ""
        }
    }

    /// Action Text's `to_plain_text`, used by FTS and notification payloads.
    public func plainText(_ body: String) -> String {
        guard body.utf8.count < 1_000_000, nestingDepth(body) <= 400 else { return "" }
        do {
            let document = try SwiftSoup.parseBodyFragment(body)
            guard let root = try document.body() else { return "" }
            try expandAttachments(in: root, forPlainText: true)
            let text = plainTextNode(root)
            return String(text.reversed().drop(while: { $0 == "\n" }).reversed())
        } catch {
            return ""
        }
    }

    private func expandAttachments(in root: Element, forPlainText: Bool = false) throws {
        for attachment in try root.select("action-text-attachment").array().reversed() {
            let contentType = try attachment.attr("content-type")
            let sgid = try attachment.attr("sgid")
            let user = resolveMention(sgid)
            if let user {
                if forPlainText {
                    try attachment.before("@\(escapeHTMLText(user.name))")
                } else {
                    let title = escapeHTMLAttribute(user.title)
                    let path = escapeHTMLAttribute(user.path)
                    let avatar = escapeHTMLAttribute(user.avatarPath)
                    let html = "<span class=\"mention\"><a title=\"\(title)\" class=\"btn avatar\" href=\"\(path)\"><img src=\"\(avatar)\" width=\"48\" height=\"48\"></a> \(escapeHTMLText(user.name))</span>"
                    try attachment.before(html)
                }
                try attachment.remove()
            } else if contentType.contains("opengraph-embed") {
                if forPlainText {
                    try attachment.before("")
                } else {
                    let content = (try? attachment.attr("content")) ?? ""
                    let html = content.isEmpty ? renderOpenGraph(attachment) : content
                    try attachment.before(html)
                }
                try attachment.remove()
            } else if let url = try? attachment.attr("url"), !url.isEmpty, contentType.hasPrefix("image/") {
                if forPlainText {
                    try attachment.before(try attachment.attr("filename"))
                } else {
                    try attachment.before("<img src=\"\(escapeHTMLAttribute(url))\">")
                }
                try attachment.remove()
            } else {
                if !forPlainText, (try? attachment.getAttributes()?.size()) == 0 { throw ActionTextRenderError.unrenderableAttachment }
                try attachment.remove()
            }
        }
    }

    private func resolveMention(_ sgid: String) -> ActionTextMentionUser? {
        guard !sgid.isEmpty, let userResolver else { return nil }
        let signedURI = verifier?.locate(sgid, purpose: "attachable", now: now())
        let uri = signedURI ?? unverifiedGlobalID(from: sgid)
        guard let uri,
              let match = mentionGlobalIDPattern?.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
              let range = Range(match.range(at: 1), in: uri), let id = Int(uri[range]) else { return nil }
        return userResolver.user(id: id)
    }


    private func renderOpenGraph(_ attachment: Element) -> String {
        let href = (try? attachment.attr("href")) ?? ""
        let url = (try? attachment.attr("url")) ?? ""
        let title = (try? attachment.attr("filename")) ?? ""
        let description = (try? attachment.attr("caption")) ?? ""
        let titleHTML = href.isEmpty ? escapeHTMLText(title) : "<a rel=\"noreferrer\" target=\"_blank\" href=\"\(escapeHTMLAttribute(href))\">\(escapeHTMLText(title))</a>"
        let imageHTML = url.isEmpty ? "" : "        <div class=\"og-embed__image\">\n          <img src=\"\(escapeHTMLAttribute(url))\" class=\"image center\" alt=\"\">\n        </div>\n"
        return "<figure class=\"attachment attachment--content attachment--og\">\n  <actiontext-opengraph-embed>\n    <div class=\"og-embed gap \"\">\n      <div class=\"og-embed__content\">\n        <div class=\"og-embed__title\">\n          \(titleHTML)\n        </div>\n        <div class=\"og-embed__description\">\(escapeHTMLText(description))</div>\n      </div>\n\(imageHTML)    </div>\n  </actiontext-opengraph-embed>\n</figure>\n"
    }

    private func autolink(_ root: Element) throws {
        guard let regex = autolinkPattern else { return }
        var textNodes: [TextNode] = []
        func collect(_ node: Node) {
            if let text = node as? TextNode { textNodes.append(text); return }
            for child in node.getChildNodes() { collect(child) }
        }
        collect(root)
        for textNode in textNodes {
            var ancestor = textNode.parent()
            var inAnchor = false
            while let current = ancestor {
                if current.nodeName().lowercased() == "a" { inAnchor = true; break }
                ancestor = current.parent()
            }
            guard !inAnchor else { continue }
            let value = textNode.getWholeText()
            let ns = value as NSString
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var output = ""
            var cursor = 0
            for match in matches {
                var range = match.range
                var token = ns.substring(with: range)
                while let last = token.last, ".,!?;:'\"".contains(last) { token.removeLast(); range.length -= String(last).utf16.count }
                while let last = token.last, [")", "]", "}"].contains(String(last)) {
                    let open = [")": "(", "]": "[", "}": "{"][String(last)]!
                    if token.filter({ String($0) == open }).count >= token.filter({ String($0) == String(last) }).count { break }
                    token.removeLast(); range.length -= 1
                }
                guard !token.isEmpty else { continue }
                output += escapeHTMLText(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                let href = token.lowercased().hasPrefix("www.") ? "http://\(token)" : token
                output += "<a target=\"_blank\" href=\"\(escapeHTMLAttribute(href))\">\(escapeHTMLText(token))</a>"
                cursor = range.location + range.length
            }
            output += escapeHTMLText(ns.substring(from: cursor))
            if let parent = textNode.parent() {
                try textNode.before(output)
                try textNode.remove()
                _ = parent
            }
        }
    }


    private func unverifiedGlobalID(from sgid: String) -> String? {
        let payload = sgid.components(separatedBy: "--").first ?? ""
        let normalized = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded),
              let envelope = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let rails = envelope["_rails"] as? [String: Any] else { return nil }
        if let uri = rails["data"] as? String { return uri }
        if let message = rails["message"] as? String {
            let normalizedMessage = message.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let messagePadded = normalizedMessage + String(repeating: "=", count: (4 - normalizedMessage.count % 4) % 4)
            if let data = Data(base64Encoded: messagePadded), let bytes = String(data: data, encoding: .isoLatin1),
               let range = bytes.range(of: #"gid://campfire/User/\d+"#, options: .regularExpression) { return String(bytes[range]) }
        }
        return nil
    }

    private func sanitize(_ root: Element) throws {
        let allowed: Set<String> = ["a", "abbr", "acronym", "address", "b", "big", "blockquote", "br", "cite", "code", "dd", "del", "dfn", "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "tt", "u", "ul", "var", "ol", "p", "pre", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "figure", "figcaption", "actiontext-opengraph-embed", "video", "audio", "source"]
        let safeAttributes: Set<String> = ["abbr", "alt", "cite", "class", "datetime", "height", "href", "lang", "src", "title", "width", "xml:lang", "data-language", "controls", "poster", "target", "rel"]
        for element in try root.getAllElements().array().reversed() where element !== root {
            let name = try element.tagName().lowercased()
            if ["script", "style", "iframe", "object", "embed", "svg", "math", "form", "input", "button", "textarea", "select"].contains(name) {
                try element.remove()
            } else if !allowed.contains(name) {
                try element.unwrap()
            }
        }
        for element in try root.getAllElements().array() {
            for attribute in (try element.getAttributes()?.asList()) ?? [] {
                let name = attribute.getKey().lowercased()
                let value = attribute.getValue()
                guard safeAttributes.contains(name), name != "name" else {
                    try element.removeAttr(attribute.getKey())
                    continue
                }
                if ["href", "src", "poster", "cite"].contains(name), !isSafeURL(value) {
                    try element.removeAttr(attribute.getKey())
                } else if name == "style" {
                    let style = safeStyle(value)
                    if style.isEmpty { try element.removeAttr("style") } else { try element.attr("style", style) }
                }
            }
        }
    }

    private func plainTextNode(_ node: Node) -> String {
        if let textNode = node as? TextNode { return textNode.getWholeText() }
        let name = node.nodeName().lowercased()
        let children = node.getChildNodes().map(plainTextNode)
        let text = children.joined()
        switch name {
        case "script", "style": return ""
        case "br": return "\n"
        case "p", "h1": return chomp(text) + "\n\n"
        case "div": return chomp(text) + "\n"
        case "figcaption": return "[\(chomp(text))]"
        case "ul", "ol": return text
        case "li":
            let ordered = node.parent()?.nodeName().lowercased() == "ol"
            if ordered, let parent = node.parent() {
                let siblings = parent.getChildNodes().compactMap { $0 as? Element }
                if let index = siblings.firstIndex(where: { $0 === node }) { return "\(index + 1). \(chomp(text))\n" }
            }
            return "• \(chomp(text))\n"
        case "blockquote":
            let value = chomp(text)
            return value.isEmpty ? "“”" : "“\(value)“".replacingOccurrences(of: "“\(value)“", with: "“\(value)\u{201d}")
        default: return text
        }
    }

    private func chomp(_ value: String) -> String { String(value.reversed().drop(while: { $0 == "\n" }).reversed()) }

    private func isSafeURL(_ value: String) -> Bool {
        let cleaned = String(value.unicodeScalars.filter { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }).lowercased()
        return !(cleaned.hasPrefix("javascript:") || cleaned.hasPrefix("vbscript:") || cleaned.hasPrefix("data:text/html") || cleaned.hasPrefix("data:image/svg"))
    }

    private func safeStyle(_ value: String) -> String {
        let safeProperties: Set<String> = ["color", "background-color", "white-space", "text-align", "font-weight", "font-style", "text-decoration"]
        return value.split(separator: ";").compactMap { declaration in
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, safeProperties.contains(pair[0].lowercased()), !pair[1].lowercased().contains("url("), !pair[1].lowercased().contains("expression") else { return nil }
            return "\(pair[0].lowercased()): \(pair[1])"
        }.joined(separator: "; ")
    }
}

private func escapeHTMLText(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

private func escapeHTMLAttribute(_ value: String) -> String {
    escapeHTMLText(value).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
}

// Compiled once; NSRegularExpression matching is thread-safe.
nonisolated(unsafe) private let mentionGlobalIDPattern = try? NSRegularExpression(pattern: #"^gid://[^/]+/User/(\d+)"#)
nonisolated(unsafe) private let autolinkPattern = try? NSRegularExpression(pattern: #"(?i)(https?://|www\.)[^\s<>"\x{A0}]+"#)
nonisolated(unsafe) private let tagPattern = try? NSRegularExpression(pattern: #"</?([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>"#)
private let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

private func nestingDepth(_ html: String) -> Int {
    guard let regex = tagPattern else { return 0 }
    let ns = html as NSString
    var depth = 0
    var maximum = 0
    for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        guard match.numberOfRanges > 1 else { continue }
        let token = ns.substring(with: match.range)
        let name = ns.substring(with: match.range(at: 1)).lowercased()
        if token.hasPrefix("</") { depth = max(0, depth - 1) }
        else if !voidTags.contains(name) && !token.hasSuffix("/>") {
            depth += 1
            maximum = max(maximum, depth)
        }
    }
    return maximum
}

private enum ActionTextRenderError: Error { case unrenderableAttachment }
