private let hexadecimalDigits = Array("0123456789abcdef".utf8)

/// Encode protocol digests without allocating and formatting a String for every byte.
func hexEncoded<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var output: [UInt8] = []
    output.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        output.append(hexadecimalDigits[Int(byte >> 4)])
        output.append(hexadecimalDigits[Int(byte & 15)])
    }
    return String(decoding: output, as: UTF8.self)
}
