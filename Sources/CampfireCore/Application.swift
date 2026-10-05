import Foundation
import Hummingbird

public func makeApplication(
    databasePath: String = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? "/rails/storage/db/production.sqlite3",
    port: Int = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80,
    eventLoopGroupProvider: EventLoopGroupProvider? = nil
) throws -> Application<RouterResponder<BasicRequestContext>> {
    let database = try SQLiteDatabase(path: databasePath)
    let router = Router()
    router.get("/up") { _, _ -> Response in
        _ = database
        return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
    }
    let group = eventLoopGroupProvider ?? .shared(EventLoopSizing.makeGroup())
    return Application(
        router: router,
        configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "campfire-swift"),
        eventLoopGroupProvider: group
    )
}
