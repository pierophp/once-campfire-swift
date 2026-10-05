import Foundation

public func erbEscape(_ input: String) -> String {
    guard input.unicodeScalars.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) else { return input }
    var output = String(); output.reserveCapacity(input.utf8.count + 16)
    for scalar in input.unicodeScalars {
        switch scalar {
        case "&": output += "&amp;"
        case "<": output += "&lt;"
        case ">": output += "&gt;"
        case "\"": output += "&quot;"
        case "'": output += "&#39;"
        default: output.unicodeScalars.append(scalar)
        }
    }
    return output
}

public func rubyStringToInt(_ input: String) -> String {
    let bytes = Array(input.utf8)
    let whitespace: Set<UInt8> = [9, 10, 11, 12, 13, 32]
    var index = 0
    while index < bytes.count && whitespace.contains(bytes[index]) { index += 1 }
    var negative = false
    if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { negative = bytes[index] == 45; index += 1 }
    if index + 1 < bytes.count && bytes[index] == 48 && (bytes[index + 1] == 100 || bytes[index + 1] == 68) { index += 2 }
    var digits: [UInt8] = []
    var previousWasDigit = false
    while index < bytes.count {
        let byte = bytes[index]
        if byte >= 48 && byte <= 57 { digits.append(byte); previousWasDigit = true; index += 1 }
        else if byte == 95 && previousWasDigit && index + 1 < bytes.count && bytes[index + 1] >= 48 && bytes[index + 1] <= 57 { previousWasDigit = false; index += 1 }
        else { break }
    }
    guard !digits.isEmpty else { return "0" }
    while digits.first == 48 && digits.count > 1 { digits.removeFirst() }
    let value = String(decoding: digits, as: UTF8.self)
    return negative && value != "0" ? "-\(value)" : value
}

public func rubyStringStrip(_ input: String) -> String {
    let bytes = Array(input.utf8)
    let stripBytes: Set<UInt8> = [0, 9, 10, 11, 12, 13, 32]
    var start = 0
    var end = bytes.count
    while start < end && stripBytes.contains(bytes[start]) { start += 1 }
    while end > start && stripBytes.contains(bytes[end - 1]) { end -= 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

public func rubyStringToFloat(_ input: String) -> String {
    let bytes = Array(input.utf8)
    var index = 0
    while index < bytes.count && [9, 10, 11, 12, 13, 32].contains(bytes[index]) { index += 1 }
    let start = index
    if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
    var digits = 0
    while index < bytes.count && ((bytes[index] >= 48 && bytes[index] <= 57) || bytes[index] == 95) {
        if bytes[index] != 95 { digits += 1 }
        index += 1
    }
    if index < bytes.count && bytes[index] == 46 {
        index += 1
        while index < bytes.count && ((bytes[index] >= 48 && bytes[index] <= 57) || bytes[index] == 95) {
            if bytes[index] != 95 { digits += 1 }
            index += 1
        }
    }
    guard digits > 0 else { return "0.0" }
    let mantissaEnd = index
    if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
        let exponentStart = index
        index += 1
        if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
        let exponentDigitsStart = index
        while index < bytes.count && ((bytes[index] >= 48 && bytes[index] <= 57) || bytes[index] == 95) { index += 1 }
        if !bytes[exponentDigitsStart..<index].contains(where: { $0 != 95 }) { index = exponentStart }
    }
    let token = bytes[start..<index].filter { $0 != 95 }
    guard let value = Double(String(decoding: token, as: UTF8.self)) else { return "0.0" }
    var result = String(value)
    if result.contains("e"), let range = result.range(of: "e"), !result[..<range.lowerBound].contains(".") {
        result.insert(contentsOf: ".0", at: range.lowerBound)
    } else if !result.contains(".") && !result.contains("e") && !result.contains("E") {
        result += ".0"
    }
    _ = mantissaEnd
    return result
}
