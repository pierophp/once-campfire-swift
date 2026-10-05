import Foundation
import Hummingbird
import NIOPosix

public enum EventLoopSizing {
    public static func availableCPUCount(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filesystem: FileManager = .default
    ) -> Int {
        let candidates: [String?] = [
            environment["CAMPFIRE_CPUSET"],
            read("/proc/self/status", matching: "Cpus_allowed_list:", using: filesystem),
            read("/sys/fs/cgroup/cpuset.cpus.effective", using: filesystem),
            read("/sys/fs/cgroup/cpuset/cpuset.cpus", using: filesystem),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let count = cpuCount(in: candidate), count > 0 { return count }
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    public static func makeGroup() -> MultiThreadedEventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: availableCPUCount())
    }

    private static func read(_ path: String, using fileSystem: FileManager = .default) -> String? {
        guard fileSystem.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func read(_ path: String, matching prefix: String, using fileSystem: FileManager) -> String? {
        guard let contents = read(path, using: fileSystem) else { return nil }
        return contents.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private static func cpuCount(in list: String) -> Int? {
        let trimmed = list.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains(":") ? String(trimmed.split(separator: ":", maxSplits: 1).last ?? "") : trimmed
        var count = 0
        for component in value.split(separator: ",") {
            let bounds = component.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            guard !bounds.isEmpty else { return nil }
            if bounds.count == 1 { count += 1 }
            else if bounds.count == 2, bounds[1] >= bounds[0] { count += bounds[1] - bounds[0] + 1 }
            else { return nil }
        }
        return count > 0 ? count : nil
    }
}
