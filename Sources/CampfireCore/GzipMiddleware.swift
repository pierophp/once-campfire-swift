import Crypto
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
        var response = try await next(request, context)
        guard shouldCompress(response) else { return response }

        addVaryAcceptEncoding(to: &response.headers)
        let accepted = parseAcceptEncoding(request.headers[.acceptEncoding] ?? "")
        guard let encoding = bestEncoding(accepted) else {
            let path = request.uri.path
            let message = "An acceptable encoding for the requested resource \(path) could not be found."
            var failure = Response(status: .notAcceptable, body: .init(byteBuffer: ByteBuffer(string: message)))
            failure.headers[.contentType] = "text/plain"
            return failure
        }
        guard encoding == "gzip" else { return response }

        let collector = BodyCollector()
        try await response.body.write(collector)
        let originalBytes = collector.buffer.readableBytesView
        let identityBody = Array(originalBytes)
        guard !identityBody.isEmpty else { return response }
        let digest = Data(SHA256.hash(data: Data(identityBody)))
        let compressed: [UInt8]
        if let cached = cache.value(for: digest) {
            compressed = cached
        } else {
            guard let generated = try? gzip(identityBody) else { return response }
            compressed = generated
            cache.insert(compressed, for: digest)
        }
        response.headers[.contentEncoding] = "gzip"
        response.body = .init(byteBuffer: ByteBuffer(bytes: compressed))
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

private func hasWord(_ value: String, _ word: String) -> Bool {
    value.split { !$0.isASCII || !( $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        .contains { $0.caseInsensitiveCompare(word) == .orderedSame }
}

private func addVaryAcceptEncoding(to headers: inout HTTPFields) {
    let values = headers[.vary]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
    guard !values.contains(where: { $0 == "*" || $0.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }) else { return }
    headers[.vary] = (values + ["Accept-Encoding"]).joined(separator: ",")
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

private func gzip(_ bytes: [UInt8]) throws -> [UInt8] {
    var stream = z_stream()
    let initialized = deflateInit2_(&stream, 6, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                                    ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else { throw GzipError.initializationFailed(initialized) }
    defer { deflateEnd(&stream) }

    var output = [UInt8](repeating: 0, count: max(256, bytes.count + bytes.count / 8 + 128))
    var outputCount = 0
    let result = bytes.withUnsafeBytes { inputBytes in
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
    }
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
    func write(_ buffer: ByteBuffer) async throws { self.buffer.writeImmutableBuffer(buffer) }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

private final class GzipCache: @unchecked Sendable {
    private struct Entry { var bytes: [UInt8]; var lastAccess: UInt64 }
    private let lock = NSLock()
    private let byteBudget = 16 * 1024 * 1024
    private var bytesInCache = 0
    private var clock: UInt64 = 0
    private var entries: [Data: Entry] = [:]

    func value(for key: Data) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry.bytes
    }

    func insert(_ compressed: [UInt8], for key: Data) {
        let cost = compressed.count + 64
        guard cost <= byteBudget / 4 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let prior = entries.removeValue(forKey: key) { bytesInCache -= prior.bytes.count + 64 }
        clock &+= 1
        entries[key] = Entry(bytes: compressed, lastAccess: clock)
        bytesInCache += cost
        while bytesInCache > byteBudget, let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            bytesInCache -= oldest.value.bytes.count + 64
            entries.removeValue(forKey: oldest.key)
        }
    }
}
