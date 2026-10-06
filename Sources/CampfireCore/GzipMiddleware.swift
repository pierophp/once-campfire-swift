import CZlib
import HTTPTypes
import Hummingbird
import NIOCore
import Foundation

/// Rack::Deflater-compatible negotiation and gzip encoding for the app's buffered responses.
struct GzipMiddleware: RouterMiddleware {
    private let cache = GzipCache()

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        let declared = ResponseBodyIdentity()
        var response = try await ResponseBodyIdentity.$current.withValue(declared) { try await next(request, context) }
        guard shouldCompress(response) else { return response }

        addVaryAcceptEncoding(to: &response.headers)
        guard let encoding = negotiatedEncoding(request.headers[.acceptEncoding] ?? "") else {
            let path = request.uri.path
            let message = "An acceptable encoding for the requested resource \(path) could not be found."
            var failure = Response(status: .notAcceptable, body: .init(byteBuffer: ByteBuffer(string: message)))
            failure.headers[.contentType] = "text/plain"
            return failure
        }
        guard encoding == "gzip" else { return response }

        // A page that declared its identity is found without reading its body.
        if let identity = declared.identity, let cached = cache.value(for: identity) {
            response.headers[.contentEncoding] = "gzip"
            response.body = .init(byteBuffer: cached)
            response.headers[.contentLength] = nil
            return response
        }

        let collector = BodyCollector()
        try await response.body.write(collector)
        let identityBody = collector.buffer
        guard identityBody.readableBytes > 0 else { return response }
        let compressed: ByteBuffer
        if declared.identity == nil, let cached = cache.value(for: identityBody) {
            compressed = cached
        } else {
            guard let generated = try? identityBody.withUnsafeReadableBytes({ try gzip($0) }) else { return response }
            compressed = ByteBuffer(bytes: generated)
            if let identity = declared.identity { cache.insert(compressed, for: identity) } else { cache.insert(compressed, for: identityBody) }
        }
        response.headers[.contentEncoding] = "gzip"
        response.body = .init(byteBuffer: compressed)
        response.headers[.contentLength] = nil
        return response
    }
}

private func shouldCompress(_ response: Response) -> Bool {
    let status = response.status.code
    guard !(100...199).contains(status), status != 204, status != 304,
          response.body.contentLength != 0 else { return false }
    if let cacheControl = response.headers[.cacheControl], hasWord(cacheControl, "no-transform") { return false }
    if let contentEncoding = response.headers[.contentEncoding], !hasWord(contentEncoding, "identity") { return false }
    return true
}

private struct WordLookup: Hashable { let value: String; let word: String }
private let headerWords = BoundedCache<WordLookup, Bool>(limit: 1_024)

private func hasWord(_ value: String, _ word: String) -> Bool {
    headerWords.value(for: WordLookup(value: value, word: word)) { findWord(value, word) }
}

private func findWord(_ value: String, _ word: String) -> Bool {
    value.split { !$0.isASCII || !( $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        .contains { $0.caseInsensitiveCompare(word) == .orderedSame }
}

private func addVaryAcceptEncoding(to headers: inout HTTPFields) {
    let values = headers[.vary]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
    guard !values.contains(where: { $0 == "*" || $0.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }) else { return }
    headers[.vary] = (values + ["Accept-Encoding"]).joined(separator: ",")
}

private let negotiatedEncodings = BoundedCache<String, String?>(limit: 1_024)

/// Negotiation is a pure function of the Accept-Encoding header, which clients repeat verbatim.
private func negotiatedEncoding(_ header: String) -> String? {
    negotiatedEncodings.value(for: header) { bestEncoding(parseAcceptEncoding(header)) }
}

private func parseAcceptEncoding(_ header: String) -> [(String, Double)] {
    header.split(separator: ",", omittingEmptySubsequences: false).prefix(16).compactMap { rawPart in
        let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !part.isEmpty else { return nil }
        let components = part.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let name = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let quality: Double
        let parameterText = components.count == 2 ? components[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if components.count == 2,
           let parameter = parameterText.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first,
           parameter == "q",
           let equalIndex = parameterText.firstIndex(of: "=") {
            let rawQ = parameterText[parameterText.index(after: equalIndex)...]
            let numeric = String(rawQ.prefix { $0.isNumber || $0 == "." })
            quality = numeric.isEmpty ? 1 : rubyFloat(numeric)
        } else {
            quality = 1
        }
        return (name, quality)
    }
}

private func rubyFloat(_ text: String) -> Double {
    var prefix = ""
    for character in text {
        guard character.isNumber || character == "." else { break }
        prefix.append(character)
    }
    let pieces = prefix.split(separator: ".", omittingEmptySubsequences: false)
    let valid = pieces.count > 1 ? pieces[0] + "." + pieces[1] : prefix
    return Double(valid) ?? 0
}

private func bestEncoding(_ accepted: [(String, Double)]) -> String? {
    let supported = ["gzip", "identity"]
    var expanded: [(String, Double, Int)] = []
    var wildcardSeen = false
    for (name, quality) in accepted {
        let preference = supported.firstIndex(of: name) ?? supported.count
        if name == "*" {
            if !wildcardSeen {
                for candidate in supported where !accepted.contains(where: { $0.0 == candidate }) {
                    expanded.append((candidate, quality, preference))
                }
                wildcardSeen = true
            }
        } else {
            expanded.append((name, quality, preference))
        }
    }
    expanded.sort { lhs, rhs in lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 > rhs.1 }
    var candidates = expanded.map(\.0)
    if !candidates.contains("identity") { candidates.append("identity") }
    for (name, quality, _) in expanded where quality == 0 { candidates.removeAll { $0 == name } }
    return candidates.first(where: { supported.contains($0) })
}

private func gzip(_ bytes: UnsafeRawBufferPointer) throws -> [UInt8] {
    var stream = z_stream()
    let initialized = deflateInit2_(&stream, 6, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                                    ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else { throw GzipError.initializationFailed(initialized) }
    defer { deflateEnd(&stream) }

    var output = [UInt8](repeating: 0, count: max(256, bytes.count + bytes.count / 8 + 128))
    var outputCount = 0
    let result = { (inputBytes: UnsafeRawBufferPointer) in
        output.withUnsafeMutableBytes { outputBytes in
            if let baseAddress = inputBytes.baseAddress {
                stream.next_in = UnsafeMutablePointer(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            }
            stream.avail_in = uInt(bytes.count)
            repeat {
                if outputCount == outputBytes.count { return Z_BUF_ERROR }
                guard let outputBase = outputBytes.baseAddress else { return Z_BUF_ERROR }
                stream.next_out = outputBase.assumingMemoryBound(to: Bytef.self).advanced(by: outputCount)
                stream.avail_out = uInt(outputBytes.count - outputCount)
                let status = deflate(&stream, Z_FINISH)
                outputCount = outputBytes.count - Int(stream.avail_out)
                if status == Z_STREAM_END { return status }
                if status != Z_OK { return status }
            } while true
        }
    }(bytes)
    guard result == Z_STREAM_END else { throw GzipError.compressionFailed(result) }
    output.removeSubrange(outputCount..<output.count)
    return output
}

private enum GzipError: Error {
    case initializationFailed(Int32)
    case compressionFailed(Int32)
}

private final class BodyCollector: ResponseBodyWriter, @unchecked Sendable {
    var buffer = ByteBuffer()
    private var written = false
    func write(_ buffer: ByteBuffer) async throws {
        // A buffered body arrives as one buffer; keep it rather than copying it.
        if written { self.buffer.writeImmutableBuffer(buffer) } else { self.buffer = buffer; written = true }
    }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

/// Compressed bodies. A body is found by the identity its page declared (see `RenderedPage`),
/// or else by CRC-32 and length confirmed by comparing the stored plain bytes, so a hit always
/// returns the gzip of exactly this body. Eviction is CLOCK (second chance), O(1) amortized.
private final class GzipCache: @unchecked Sendable {
    private enum Key: Hashable {
        case declared(BodyIdentity)
        case content(length: Int, crc: UInt)
    }
    private struct Entry { let plain: ByteBuffer?; let compressed: ByteBuffer; var referenced: Bool }
    private let lock = NSLock()
    private let byteBudget = 32 * 1024 * 1024
    private var bytesInCache = 0
    private var entries: [Key: Entry] = [:]
    private var queue: [Key] = []
    private var head = 0

    private static func key(_ body: ByteBuffer) -> Key {
        body.withUnsafeReadableBytes { bytes in
            .content(length: bytes.count, crc: UInt(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))))
        }
    }

    private static func cost(_ entry: Entry) -> Int { (entry.plain?.readableBytes ?? 0) + entry.compressed.readableBytes + 128 }

    func value(for identity: BodyIdentity) -> ByteBuffer? { lookup(.declared(identity))?.compressed }

    func value(for plain: ByteBuffer) -> ByteBuffer? {
        guard let entry = lookup(Self.key(plain)), entry.plain == plain else { return nil }
        return entry.compressed
    }

    func insert(_ compressed: ByteBuffer, for identity: BodyIdentity) {
        store(Entry(plain: nil, compressed: compressed, referenced: false), for: .declared(identity))
    }

    func insert(_ compressed: ByteBuffer, for plain: ByteBuffer) {
        store(Entry(plain: plain, compressed: compressed, referenced: false), for: Self.key(plain))
    }

    private func lookup(_ key: Key) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        if !entry.referenced { entry.referenced = true; entries[key] = entry }
        return entry
    }

    private func store(_ entry: Entry, for key: Key) {
        let cost = Self.cost(entry)
        guard cost <= byteBudget / 4 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let prior = entries.updateValue(entry, forKey: key) {
            bytesInCache -= Self.cost(prior)
        } else {
            queue.append(key)
        }
        bytesInCache += cost
        while bytesInCache > byteBudget && head < queue.count {
            let candidate = queue[head]; head += 1
            guard var victim = entries[candidate] else { continue }
            if victim.referenced {
                victim.referenced = false
                entries[candidate] = victim
                queue.append(candidate)
            } else {
                bytesInCache -= Self.cost(victim)
                entries.removeValue(forKey: candidate)
            }
        }
        if head > 1_024 && head * 2 > queue.count { queue.removeFirst(head); head = 0 }
    }
}
