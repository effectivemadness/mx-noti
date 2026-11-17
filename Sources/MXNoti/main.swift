import AppKit
import Foundation
import MXNotiCore

let arguments = Array(CommandLine.arguments.dropFirst())
func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func wakeApplication() {
    let bundle = Bundle.main.bundleURL
    guard ProcessInfo.processInfo.environment["MX_NOTI_DATA_DIR"] == nil, bundle.pathExtension == "app",
          NSRunningApplication.runningApplications(withBundleIdentifier: "local.mx-noti").allSatisfy({ $0.processIdentifier == getpid() }) else { return }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", bundle.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try? process.run()
}

if arguments.first == "--probe" {
    do { try printJSON(Haptics.status()) } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.first == "--play" {
    guard arguments.count == 1 || EventKind(rawValue: arguments[1]) != nil || UInt8(arguments[1]).flatMap(Waveform.init(rawValue:)) != nil else {
        fputs("알 수 없는 진동 패턴입니다. --help를 확인해주세요.\n", stderr); exit(64)
    }
    let wave: Waveform = arguments.count > 1 ? (EventKind(rawValue: arguments[1])?.defaultWaveform ?? UInt8(arguments[1]).flatMap(Waveform.init(rawValue:))!) : .completed
    do { try printJSON(Haptics.play(wave)) } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.first == "--hook", arguments.count >= 2, let source = AgentSource(rawValue: arguments[1]) {
    // A notification hook must never affect the agent's decision or print model-visible output.
    // The producer always closes stdin; cap the input before parsing, without retaining its text.
    let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
    let payload = data.count <= 1_048_576 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] : [:]
    let override = arguments.firstIndex(of: "--event").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    if let event = AgentEvent.fromHook(source: source, payload: payload, eventOverride: override) {
        try? LocalStore().enqueue(event)
        wakeApplication()
    }
} else if arguments.first == "--emit", arguments.count >= 3,
          let source = AgentSource(rawValue: arguments[1]), let kind = EventKind(rawValue: arguments[2]) {
    do { try LocalStore().enqueue(AgentEvent(source: source, kind: kind, origin: "manual")); wakeApplication() }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if ["--install-hooks", "--remove-hooks"].contains(arguments.first ?? "") {
    let names = Array(arguments.dropFirst())
    let sources = names.isEmpty ? [AgentSource.claude, .codex, .kiro] : names.compactMap(AgentSource.init(rawValue:))
    guard names.isEmpty || (sources.count == names.count && sources.allSatisfy({ [.claude, .codex, .kiro].contains($0) })) else {
        fputs("연결할 도구는 claude, codex, kiro 중에서 선택해주세요.\n", stderr); exit(64)
    }
    let installer = IntegrationInstaller(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    do { try printJSON(try sources.map { try installer.install($0, remove: arguments.first == "--remove-hooks") }) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.first == "--kiro-project", arguments.count == 2 {
    let installer = IntegrationInstaller(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    do { try printJSON(installer.installKiro(directory: URL(fileURLWithPath: arguments[1]))) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.first == "--help" {
    print("MX Noti\n  --probe                    마우스 연결 및 햅틱 상태\n  --play [completed|approval|패턴번호]  진동 테스트\n  --hook claude|codex|kiro|crew        훅 JSON을 stdin으로 받기\n  --emit custom completed|approval|question|error|tool\n  --install-hooks [claude codex kiro]  기존 설정을 백업하고 연결\n  --remove-hooks [claude codex kiro]   MX Noti 훅만 해제\n  --kiro-project /절대/경로           Kiro IDE 프로젝트 연결")
} else if arguments.isEmpty {
    MXNotiApplication.main()
} else {
    fputs("알 수 없는 명령입니다. --help를 확인해주세요.\n", stderr); exit(64)
}
