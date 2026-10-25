import Foundation

struct ProtoWireReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw ProtobufError.malformed }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            let byte = try byte()
            guard index != 9 || byte <= 1 else { throw ProtobufError.malformed }
            result |= UInt64(byte & 127) << (index * 7)
            if byte & 128 == 0 { return result }
        }
        throw ProtobufError.malformed
    }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ProtobufError.malformed }
        defer { offset += count }
        return Data(data.dropFirst(offset).prefix(count))
    }
    mutating func delimited(limit: Int = 1024 * 1024) throws -> Data {
        let size = try varint()
        guard size <= limit else { throw BrokerError.limit }
        return try bytes(Int(size))
    }
    mutating func fixed(_ count: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<count { result |= UInt64(try byte()) << (index * 8) }
        return result
    }
    mutating func skip(_ wire: Int, field: UInt64, depth: Int = 0) throws {
        guard depth < 32 else { throw BrokerError.limit }
        switch wire {
        case 0: _ = try varint()
        case 1: _ = try bytes(8)
        case 2: _ = try delimited()
        case 3:
            while remaining > 0 {
                let tag = try varint()
                guard tag >> 3 > 0 else { throw ProtobufError.malformed }
                if tag & 7 == 4 {
                    guard tag >> 3 == field else { throw ProtobufError.malformed }
                    return
                }
                try skip(Int(tag & 7), field: tag >> 3, depth: depth + 1)
            }
            throw ProtobufError.malformed
        case 5: _ = try bytes(4)
        default: throw ProtobufError.malformed
        }
    }
}
enum ProtoWire {
    static func varint(_ input: UInt64) -> Data {
        var value = input
        var result = Data()
        repeat {
            var next = UInt8(value & 127)
            value >>= 7
            if value != 0 { next |= 128 }
            result.append(next)
        } while value != 0
        return result
    }
    static func fixed(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func field(_ number: Int32, wire: UInt64, _ data: Data) -> Data {
        varint((UInt64(number) << 3) | wire) + data
    }
    static func delimited(_ data: Data) -> Data { varint(UInt64(data.count)) + data }
}
