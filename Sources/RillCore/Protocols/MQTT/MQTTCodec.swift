import Foundation

public enum MQTTVersion: String, CaseIterable, Codable, Sendable { case v311 = "3.1.1", v5 = "5.0" }
public enum MQTTQoS: Int, CaseIterable, Codable, Sendable { case atMostOnce = 0, atLeastOnce = 1, exactlyOnce = 2 }
struct MQTTPacket: Sendable { let header: UInt8; let body: Data; var type: UInt8 { header >> 4 } }
struct MQTTDecoder {
    private var bytes = Data()
    mutating func append(_ data: Data) throws -> [MQTTPacket] {
        guard bytes.count <= 2 * 1024 * 1024 - data.count else { throw BrokerError.limit }
        bytes.append(data); var packets: [MQTTPacket] = []
        while bytes.count >= 2 {
            var length = 0, factor = 1, index = 1, finished = false
            while index < bytes.count && index <= 4 {
                let byte = bytes[bytes.startIndex + index]; length += Int(byte & 127) * factor; index += 1
                if byte & 128 == 0 { guard index == 2 || byte != 0 else { throw BrokerError.protocolFailure }; finished = true; break }
                factor *= 128
            }
            guard length <= 1024 * 1024 + 16384 else { throw BrokerError.limit }
            if !finished { guard index <= 4 else { throw BrokerError.protocolFailure }; break }
            guard bytes.count >= index + length else { break }
            packets.append(MQTTPacket(header: bytes[bytes.startIndex], body: Data(bytes.dropFirst(index).prefix(length))))
            bytes = Data(bytes.dropFirst(index + length))
            guard packets.count <= 1024 else { throw BrokerError.limit }
        }
        return packets
    }
}
struct MQTTReader {
    let data: Data; var position = 0
    var remaining: Int { data.count - position }
    mutating func byte() throws -> UInt8 { guard position < data.count else { throw BrokerError.protocolFailure }; defer { position += 1 }; return data[data.startIndex + position] }
    mutating func u16() throws -> UInt16 { (UInt16(try byte()) << 8) | UInt16(try byte()) }
    mutating func take(_ count: Int) throws -> Data { guard count >= 0, count <= remaining else { throw BrokerError.protocolFailure }; defer { position += count }; return Data(data.dropFirst(position).prefix(count)) }
    mutating func variable() throws -> Int {
        var result = 0, factor = 1
        for index in 0..<4 { let next = try byte(); result += Int(next & 127) * factor; if next & 128 == 0 { guard index == 0 || next != 0 else { throw BrokerError.protocolFailure }; return result }; factor *= 128 }
        throw BrokerError.protocolFailure
    }
    mutating func string() throws -> String { let bytes = try take(Int(u16())); guard let text = String(data: bytes, encoding: .utf8), MQTTEncoding.validText(text) else { throw BrokerError.protocolFailure }; return text }
    mutating func properties() throws -> [Int: [Data]] {
        let size = try variable(); guard size <= 16384 else { throw BrokerError.limit }
        var reader = MQTTReader(data: try take(size)), result: [Int: [Data]] = [:], count = 0
        while reader.remaining > 0 {
            count += 1; guard count <= 128 else { throw BrokerError.limit }; let identifier = try reader.variable(), start = reader.position
            switch identifier {
            case 1, 0x17, 0x19, 0x24, 0x25, 0x28, 0x29, 0x2A: _ = try reader.take(1)
            case 0x13, 0x21, 0x22, 0x23: _ = try reader.take(2)
            case 2, 0x11, 0x18, 0x27: _ = try reader.take(4)
            case 3, 8, 0x12, 0x15, 0x1A, 0x1C, 0x1F: _ = try reader.string()
            case 9, 0x16: _ = try reader.take(Int(reader.u16()))
            case 0x0B: _ = try reader.variable()
            case 0x26: _ = try reader.string(); _ = try reader.string()
            default: throw BrokerError.protocolFailure
            }
            if identifier != 0x26 && identifier != 0x0B && result[identifier] != nil { throw BrokerError.protocolFailure }
            result[identifier, default: []].append(Data(reader.data.dropFirst(start).prefix(reader.position - start)))
        }
        return result
    }
}
enum MQTTEncoding {
    static func validText(_ value: String) -> Bool { value.unicodeScalars.allSatisfy { let n = $0.value; return n != 0 && !(0xFDD0...0xFDEF).contains(n) && n & 0xFFFF < 0xFFFE } }
    static func u16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 255)]) }
    static func string(_ value: String) throws -> Data { let data = Data(value.utf8); guard data.count <= 65535, validText(value) else { throw BrokerError.configuration }; return u16(UInt16(data.count)) + data }
    static func variable(_ input: Int) -> Data { var value = input, result = Data(); repeat { var byte = UInt8(value % 128); value /= 128; if value > 0 { byte |= 128 }; result.append(byte) } while value > 0; return result }
    static func packet(_ header: UInt8, _ body: Data = Data()) throws -> Data { guard body.count <= 1024 * 1024 + 16384 else { throw BrokerError.limit }; return Data([header]) + variable(body.count) + body }
    static func topic(_ value: String, subscription: Bool) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 65535, validText(value) else { return false }
        if !subscription { return !value.contains("#") && !value.contains("+") }
        let levels = value.split(separator: "/", omittingEmptySubsequences: false)
        return levels.enumerated().allSatisfy { index, level in
            (!level.contains("#") || (level == "#" && index == levels.count - 1)) && (!level.contains("+") || level == "+")
        }
    }
}
