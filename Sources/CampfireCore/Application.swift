import Foundation
import Hummingbird
import HTTPTypes

public func makeApplication(
    databasePath: String = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? "/rails/storage/db/production.sqlite3",
    port: Int = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80,
    eventLoopGroupProvider: EventLoopGroupProvider? = nil,
    database suppliedDatabase: SQLiteDatabase? = nil
) throws -> Application<RouterResponder<BasicRequestContext>> {
    let database = try suppliedDatabase ?? SQLiteDatabase(path: databasePath)
    let router = Router()
    router.addMiddleware { GzipMiddleware() }
    installLoginRoutes(on: router, database: database)
    installSidebarRoutes(on: router, database: database)
    router.get("/assets/flash-a561c1e5.css") { _, _ -> Response in
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: ":root{color-scheme:light dark}.sidebar{display:block}.flash{padding:.5rem}")))
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
