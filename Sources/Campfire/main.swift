import CampfireCore
import Foundation
import Hummingbird

@main
struct CampfireServer {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["HTTP_PORT"] ?? "80") ?? 80
        let application = try makeApplication(port: port)
        try await application.runService()
    }
}
