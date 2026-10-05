import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

private let squareWebPDigest = "6gwfjNKv9eUy9jNUtEZvQFLU0hQ="

func installAvatarRoutes(on router: Router<BasicRequestContext>, database: SQLiteDatabase, filesPath: String) {
    router.get("/users/:avatar_token/avatar") { request, context async throws -> Response in
        guard let session = try await SessionPipeline.load(request, database: database) else {
            var response = Response(status: .seeOther)
            response.headers[.location] = "/session/new"
            return response
        }
        _ = session

        let token = context.parameters.get("avatar_token") ?? ""
        let secret = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"] ?? "campfire-swift-development-secret-key-base"
        let now = ISO8601DateFormatter().string(from: Date())
        guard let userID = RailsSignedID(secretKeyBase: secret).verify(token, model: "User", purpose: "avatar", now: now) else {
            return Response(status: .notFound)
        }
        guard let originalBlobID = try await Task.detached(operation: {
            try database.read { connection in
                try connection.firstRow("""
                    SELECT b.id
                    FROM users u
                    INNER JOIN active_storage_attachments a
                      ON a.record_type='User' AND a.record_id=u.id AND a.name='avatar'
                    INNER JOIN active_storage_blobs b ON b.id=a.blob_id
                    WHERE u.id=?
                    LIMIT 1
                    """, bindings: [.integer(Int64(userID))])?.integer(0)
            }
        }).value else { return Response(status: .notFound) }

        guard let variant = try await Task.detached(operation: {
            try database.read { connection in
                try connection.firstRow("""
                    SELECT b.key, b.filename, b.content_type
                    FROM active_storage_variant_records v
                    INNER JOIN active_storage_attachments a
                      ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id AND a.name='image'
                    INNER JOIN active_storage_blobs b ON b.id=a.blob_id
                    WHERE v.blob_id=? AND v.variation_digest=?
                    LIMIT 1
                    """, bindings: [.integer(originalBlobID), .text(squareWebPDigest)])
            }
        }).value,
        let variantKey = variant.string(0),
        let filename = variant.string(1),
        let contentType = variant.string(2),
        variantKey.utf8.count >= 5,
        variantKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            return Response(status: .notFound)
        }

        let fileURL = URL(fileURLWithPath: filesPath, isDirectory: true)
            .appending(path: String(variantKey.prefix(2)), directoryHint: .isDirectory)
            .appending(path: String(variantKey.dropFirst(2).prefix(2)), directoryHint: .isDirectory)
            .appending(path: variantKey)
        guard let data = try? await Task.detached(operation: { try Data(contentsOf: fileURL) }).value else {
            return Response(status: .notFound)
        }
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
        response.headers[.contentType] = contentType
        response.headers[.contentDisposition] = inlineDisposition(filename)
        response.headers[.cacheControl] = "max-age=1800, public, stale-while-revalidate=604800"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attributes[.modificationDate] as? Date {
            response.headers[HTTPField.Name("last-modified")!] = httpDate(modified)
        }
        return response
    }
}

func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
}

private func inlineDisposition(_ filename: String) -> String {
    let safe = filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
    let encoded = safe.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? safe
    return "inline; filename=\"\(safe)\"; filename*=UTF-8''\(encoded)"
}
