import Foundation
import IOKit.hid

public struct MouseStatus: Codable, Sendable {
    public let connected: Bool
    public let product: String
    public let transport: String
    public let enabled: Bool
    public let level: Int
    public let feature: UInt8
    public let waveforms: [UInt8]
}

public enum Haptics {
    public static func status() throws -> MouseStatus { try Connection().status() }
    public static func play(_ waveform: Waveform) throws -> MouseStatus {
        let connection = try Connection()
        let status = try connection.status()
        guard status.enabled else { throw HIDFailure.message("Logi Options+에서 마우스 햅틱을 켜주세요.") }
        guard status.waveforms.contains(waveform.rawValue) else {
            throw HIDFailure.message("이 마우스가 선택한 진동 패턴을 지원하지 않습니다.")
        }
        // Never write configuration (function 2). Playback respects the user's Options+ intensity.
        var ready = false
        for _ in 0..<8 {
            if try connection.request(feature: status.feature, function: 3).first == 0 { ready = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard ready else { throw HIDFailure.message("마우스가 다른 진동을 재생 중입니다. 잠시 후 다시 시도해주세요.") }
        _ = try connection.request(feature: status.feature, function: 4, parameters: [waveform.rawValue, 0, 0])
        return status
    }
}

private final class Connection {
    let manager: IOHIDManager
    var device: IOHIDDevice?
    var feature: UInt8 = 0
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private var reports: [[UInt8]] = []
    private let runLoop = CFRunLoopGetCurrent()!

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xB042] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw HIDFailure.message("블루투스로 연결된 MX Master 4를 찾지 못했습니다. 마우스를 깨우고 연결을 확인해주세요.")
        }
        var failure = "마우스의 HID++ 연결을 열 수 없습니다. 시스템 설정의 개인정보 보호 및 보안 → 입력 모니터링을 확인해주세요."
        for candidate in devices {
            let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                failure = String(format: "마우스 접근이 거부되었습니다 (0x%08X). 시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링에서 MX Noti를 허용한 뒤 앱을 다시 실행해주세요.", result)
                continue
            }
            device = candidate
            IOHIDDeviceRegisterInputReportCallback(candidate, buffer, 128, { context, result, _, _, reportID, bytes, count in
                guard result == kIOReturnSuccess, let context, count > 0 else { return }
                let connection = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
                var raw = Array(UnsafeBufferPointer(start: bytes, count: count))
                if raw.first != UInt8(truncatingIfNeeded: reportID) && [0x10, 0x11].contains(reportID) {
                    raw.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
                }
                if connection.reports.count < 256 { connection.reports.append(raw) }
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(candidate, runLoop, CFRunLoopMode.defaultMode.rawValue)
            do {
                let response = try request(feature: 0, function: 0, parameters: [0x19, 0xB0, 0])
                guard let index = response.first, index > 0 else { throw HIDFailure.message("마우스가 햅틱 기능 0x19B0을 제공하지 않습니다.") }
                feature = index
                return
            } catch {
                failure = error.localizedDescription
                closeDevice()
            }
        }
        throw HIDFailure.message(failure)
    }

    func request(feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws -> [UInt8] {
        guard let device else { throw HIDFailure.message("마우스 연결이 끊어졌습니다.") }
        let packet = HIDProtocol.packet(feature: feature, function: function, parameters: parameters)
        reports.removeAll(keepingCapacity: true)
        let result = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), $0.baseAddress!, packet.count)
        }
        guard result == kIOReturnSuccess else {
            throw HIDFailure.message(String(format: "마우스에 명령을 보낼 수 없습니다 (0x%08X). 블루투스 연결과 입력 모니터링 권한을 확인해주세요.", result))
        }
        let deadline = Date().addingTimeInterval(1.2)
        repeat {
            while !reports.isEmpty {
                if let reply = try HIDProtocol.reply(reports.removeFirst(), for: packet) { return reply }
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.005, false)
        } while Date() < deadline
        throw HIDFailure.message("마우스 응답 시간이 초과되었습니다. 마우스를 움직인 뒤 다시 연결해주세요.")
    }

    func status() throws -> MouseStatus {
        let capabilities = try request(feature: feature, function: 0)
        let config = try request(feature: feature, function: 1)
        guard config.count >= 2, let device else { throw HIDFailure.message("마우스 설정 응답을 읽을 수 없습니다.") }
        return MouseStatus(connected: true,
            product: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "MX Master 4",
            transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Bluetooth",
            enabled: config[0] & 1 != 0, level: Int(config[1]), feature: feature,
            waveforms: try HIDProtocol.supportedWaveforms(capabilities))
    }

    private func closeDevice() {
        guard let device else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
    }
    deinit {
        closeDevice()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }
}
