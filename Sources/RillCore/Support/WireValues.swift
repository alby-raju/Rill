import Foundation

struct WireCursor {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw BrokerError.protocolFailure }
        defer { offset += count }
        return Data(data.dropFirst(offset).prefix(count))
    }
    mutating func u8() throws -> UInt8 {
        guard remaining > 0 else { throw BrokerError.protocolFailure }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func u16() throws -> UInt16 { (UInt16(try u8()) << 8) | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try u8()) }
        return value
    }
    mutating func u64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(try u8()) }
        return value
    }
    mutating func shortString() throws -> String { try text(Int(u8())) }
    mutating func longBytes(limit: Int = 1024 * 1024) throws -> Data {
        let count = Int(try u32())
        guard count <= limit else { throw BrokerError.limit }
        return try take(count)
    }
    mutating func text(_ count: Int) throws -> String {
        guard let string = String(data: try take(count), encoding: .utf8) else {
            throw BrokerError.protocolFailure
        }
        return string
    }
    mutating func table(depth: Int = 0) throws {
        guard depth <= 16 else { throw BrokerError.limit }
        let bytes = try longBytes(limit: 16384)
        var cursor = WireCursor(data: bytes)
        var count = 0
        while cursor.remaining > 0 {
            _ = try cursor.shortString()
            count += 1
            guard count <= 256 else { throw BrokerError.limit }
            try cursor.field(depth: depth + 1)
        }
    }
    private mutating func field(depth: Int) throws {
        guard depth <= 16 else { throw BrokerError.limit }
        switch try u8() {
        case 116, 98, 66: _ = try take(1)
        case 85, 117: _ = try take(2)
        case 73, 105, 102: _ = try take(4)
        case 76, 108, 100, 84: _ = try take(8)
        case 68: _ = try take(5)
        case 115: _ = try shortString()
        case 83, 120: _ = try longBytes(limit: 16384)
        case 70: try table(depth: depth + 1)
        case 65:
            var array = WireCursor(data: try longBytes(limit: 16384))
            var count = 0
            while array.remaining > 0 {
                count += 1
                guard count <= 256 else { throw BrokerError.limit }
                try array.field(depth: depth + 1)
            }
        case 86: break
        default: throw BrokerError.protocolFailure
        }
    }
}
enum WireValue {
    static func u16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 255)]) }
    static func u32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) })
    }
    static func u64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: value >> ((7 - $0) * 8)) })
    }
    static func shortString(_ value: String) throws -> Data {
        let bytes = Data(value.utf8)
        guard bytes.count <= 255, !value.contains("\0") else { throw BrokerError.configuration }
        return Data([UInt8(bytes.count)]) + bytes
    }
    static func longBytes(_ value: Data) throws -> Data {
        guard value.count <= 1024 * 1024 else { throw BrokerError.limit }
        return u32(UInt32(value.count)) + value
    }
}
struct AMQPFrame: Sendable {
    let kind: UInt8
    let channel: UInt16
    let payload: Data
}
struct AMQPDecoder {
    private var bytes = Data()
    var maximumFrame = 65536
    mutating func append(_ data: Data) throws -> [AMQPFrame] {
        guard bytes.count <= 2 * 1024 * 1024 - data.count else { throw BrokerError.limit }
        bytes += data
        var frames: [AMQPFrame] = []
        while bytes.count >= 7 {
            var reader = WireCursor(data: bytes)
            let kind = try reader.u8()
            let channel = try reader.u16()
            let size = Int(try reader.u32())
            guard size + 8 <= maximumFrame else { throw BrokerError.limit }
            guard bytes.count >= size + 8 else { break }
            let payload = try reader.take(size)
            guard try reader.u8() == 0xCE else { throw BrokerError.protocolFailure }
            guard [1, 2, 3, 8].contains(kind), kind != 8 || (channel == 0 && payload.isEmpty) else {
                throw BrokerError.protocolFailure
            }
            frames.append(AMQPFrame(kind: kind, channel: channel, payload: payload))
            bytes = Data(bytes.dropFirst(size + 8))
            guard frames.count <= 1024 else { throw BrokerError.limit }
        }
        return frames
    }
}
enum AMQPEncoding {
    static func frame(_ kind: UInt8, channel: UInt16 = 0, payload: Data = Data()) throws -> Data {
        guard payload.count <= 65528 else { throw BrokerError.limit }
        return Data([kind]) + WireValue.u16(channel) + WireValue.u32(UInt32(payload.count))
            + payload + Data([0xCE])
    }
    static func method(
        _ group: UInt16, _ method: UInt16, channel: UInt16 = 0, arguments: Data = Data()
    ) throws -> Data {
        try frame(
            1, channel: channel, payload: WireValue.u16(group) + WireValue.u16(method) + arguments)
    }
}
