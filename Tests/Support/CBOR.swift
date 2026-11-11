import Foundation

indirect enum CBOR: Hashable {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([CBOR: CBOR])
}

struct CBORReader {
    enum Failure: Error { case truncated, unsupported(UInt8) }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    var atEnd: Bool { index == bytes.count }

    mutating func next() throws -> CBOR {
        let head = try take(1)[0]
        let n = try length(head & 0x1f)
        switch head >> 5 {
        case 0: return .int(n)
        case 1: return .int(-1 - n)
        case 2: return .bytes(Data(try take(n)))
        case 3: return .text(String(decoding: try take(n), as: UTF8.self))
        case 5:
            var m: [CBOR: CBOR] = [:]
            for _ in 0..<n {
                let k = try next()
                m[k] = try next()
            }
            return .map(m)
        default: throw Failure.unsupported(head)
        }
    }

    private mutating func length(_ info: UInt8) throws -> Int {
        switch info {
        case 0..<24: return Int(info)
        case 24: return try take(1).reduce(0) { $0 << 8 | Int($1) }
        case 25: return try take(2).reduce(0) { $0 << 8 | Int($1) }
        case 26: return try take(4).reduce(0) { $0 << 8 | Int($1) }
        default: throw Failure.unsupported(info)
        }
    }

    private mutating func take(_ n: Int) throws -> [UInt8] {
        guard index + n <= bytes.count else { throw Failure.truncated }
        defer { index += n }
        return Array(bytes[index..<index + n])
    }
}
