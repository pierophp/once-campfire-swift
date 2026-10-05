import Foundation
import Hummingbird

public func makeApplication(
    databasePath: String = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? "/rails/storage/db/production.sqlite3",
    port: Int = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80,
    eventLoopGroupProvider: EventLoopGroupProvider? = nil,
    database suppliedDatabase: SQLiteDatabase? = nil
) throws -> Application<RouterResponder<BasicRequestContext>> {
    let database = try suppliedDatabase ?? SQLiteDatabase(path: databasePath)
    let router = Router()
    installLoginRoutes(on: router, database: database)
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
