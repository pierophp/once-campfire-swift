import Foundation
import NIOCore

enum StaticAssets {
    static let flashStylesheet: ByteBuffer = {
        guard let url = Bundle.module.url(forResource: "flash", withExtension: "css", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing embedded flash stylesheet")
        }
        return ByteBuffer(data: data)
    }()
}
