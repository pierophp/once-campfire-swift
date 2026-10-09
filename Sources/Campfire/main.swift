import CampfireCore
import Foundation
import Hummingbird
import NIOCore
import NIOPosix

@main
struct CampfireServer {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80
        // Swift Concurrency jobs run on the NIO event loops instead of the global cooperative
        // pool, so a request is parsed, handled and written on one thread, as the C port's loops
        // do, without two thread hand-offs per request. The singleton group gets one loop per
        // CPU this process may run on. CAMPFIRE_EVENT_LOOP_EXECUTOR=0 keeps the default pool.
        NIOSingletons.groupLoopCountSuggestion = EventLoopSizing.availableCPUCount()
        if ProcessInfo.processInfo.environment["CAMPFIRE_EVENT_LOOP_EXECUTOR"] != "0" {
            NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        }
        let application = try makeApplication(port: port, eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
        try await application.runService()
    }
}
