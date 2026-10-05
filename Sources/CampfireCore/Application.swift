import Foundation
import Hummingbird
import HTTPTypes

public func makeApplication(
    databasePath: String = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? "/rails/storage/db/production.sqlite3",
    port: Int = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80,
    eventLoopGroupProvider: EventLoopGroupProvider? = nil,
    database suppliedDatabase: SQLiteDatabase? = nil,
    avatarFilesPath: String = ProcessInfo.processInfo.environment["CAMPFIRE_FILES_PATH"] ?? "/rails/storage/files"
) throws -> Application<RouterResponder<BasicRequestContext>> {
    let database = try suppliedDatabase ?? SQLiteDatabase(path: databasePath)
    let fragmentCache = MessageFragmentCache(maxBytes: Int(ProcessInfo.processInfo.environment["FRAGMENT_CACHE_BYTES"] ?? "33554432") ?? 33_554_432)
    let router = Router()
    router.addMiddleware { GzipMiddleware() }
    installLoginRoutes(on: router, database: database)
    installSidebarRoutes(on: router, database: database)
    installRoomRoutes(on: router, database: database, fragmentCache: fragmentCache)
    installAvatarRoutes(on: router, database: database, filesPath: avatarFilesPath)
    router.get("/assets/flash-a561c1e5.css") { _, _ -> Response in
        var response = Response(status: .ok, body: .init(byteBuffer: StaticAssets.flashStylesheet))
        response.headers[.contentType] = "text/css; charset=utf-8"
        response.headers[HTTPField.Name("cache-control")!] = "public, max-age=2592000"
        return response
    }
    router.get("/up") { _, _ -> Response in
        return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
    }
    let group = eventLoopGroupProvider ?? .shared(EventLoopSizing.makeGroup())
    return Application(
        router: router,
        configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "campfire-swift"),
        eventLoopGroupProvider: group
    )
}
