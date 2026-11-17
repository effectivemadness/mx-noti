import Foundation

public enum HIDFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum HIDProtocol {
    public static let softwareID: UInt8 = 0x0D
    public static func packet(device: UInt8 = 0xFF, feature: UInt8, function: UInt8, parameters: [UInt8] = []) -> [UInt8] {
        var report: [UInt8] = [0x11, device, feature, (function << 4) | softwareID]
        report += parameters.prefix(16)
        report += Array(repeating: 0, count: 20 - report.count)
        return report
    }
    public static func reply(_ raw: [UInt8], for packet: [UInt8]) throws -> [UInt8]? {
        guard raw.count >= 7, [UInt8(0x10), UInt8(0x11)].contains(raw[0]),
              raw[1] == packet[1] || (packet[1] == 0xFF && raw[1] == 0) else { return nil }
        if raw[2] == 0xFF && raw[3] == packet[2] && raw[4] == packet[3] {
            throw HIDFailure.message(String(format: "마우스가 HID++ 오류 0x%02X를 반환했습니다.", raw[5]))
        }
        guard raw[2] == packet[2], raw[3] == packet[3] else { return nil }
        return Array(raw.dropFirst(4))
    }
    public static func supportedWaveforms(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 8 else { throw HIDFailure.message("진동 패턴 응답이 너무 짧습니다.") }
        let mask = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (0..<32).compactMap { mask & (UInt32(1) << $0) != 0 ? UInt8($0) : nil }
    }
}
