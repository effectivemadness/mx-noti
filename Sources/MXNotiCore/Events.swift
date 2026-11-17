import CryptoKit
import Foundation

public enum AgentSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, kiro, crew, chatgpt, claudeDesktop, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .kiro: return "Kiro"
        case .crew: return "Kiro Crew"
        case .chatgpt: return "ChatGPT 앱"
        case .claudeDesktop: return "Claude 앱"
        case .custom: return "직접 연결"
        }
    }
}

public enum EventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case completed, approval, question, error, tool, notification
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .completed: return "응답 완료"
        case .approval: return "승인 요청"
        case .question: return "입력 대기"
        case .error: return "오류 발생"
        case .tool: return "도구 실행 직전"
        case .notification: return "앱 알림"
        }
    }
    public var symbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .approval: return "hand.raised.fill"
        case .question: return "bubble.left.and.bubble.right.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .tool: return "wrench.and.screwdriver.fill"
        case .notification: return "bell.fill"
        }
    }
    public var defaultWaveform: Waveform {
        switch self {
        case .completed: return .completed
        case .approval: return .knock
        case .question: return .ringing
        case .error: return .angryAlert
        case .tool: return .subtleCollision
        case .notification: return .happyAlert
        }
    }
}

public enum Waveform: UInt8, Codable, CaseIterable, Identifiable, Sendable {
    case sharpStateChange = 0, dampStateChange = 1, sharpCollision = 2
    case dampCollision = 3, subtleCollision = 4, happyAlert = 5
    case angryAlert = 6, completed = 7, square = 8, wave = 9
    case firework = 10, mad = 11, knock = 12, jingle = 13, ringing = 14
    case whisperCollision = 27
    public var id: UInt8 { rawValue }
    public var title: String {
        switch self {
        case .sharpStateChange: return "선명한 전환"
        case .dampStateChange: return "부드러운 전환"
        case .sharpCollision: return "선명한 탭"
        case .dampCollision: return "부드러운 탭"
        case .subtleCollision: return "작은 탭"
        case .happyAlert: return "경쾌한 알림"
        case .angryAlert: return "강한 알림"
        case .completed: return "완료"
        case .square: return "사각 파동"
        case .wave: return "물결"
        case .firework: return "불꽃"
        case .mad: return "거친 알림"
        case .knock: return "노크"
        case .jingle: return "징글"
        case .ringing: return "벨"
        case .whisperCollision: return "아주 작은 탭"
        }
    }
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var source: AgentSource
    public var kind: EventKind
    public var session: String
    public var origin: String

    public init(source: AgentSource, kind: EventKind, session: String = "", origin: String = "hook", date: Date = Date()) {
        self.id = UUID(); self.date = date; self.source = source
        self.kind = kind; self.session = session; self.origin = origin
    }

    // Keep only a one-way session fingerprint. Prompts, commands and replies never enter the inbox.
    public static func fingerprint(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func fromHook(source: AgentSource, payload: [String: Any], eventOverride: String? = nil) -> AgentEvent? {
        if let subagent = payload["subagent_id"] as? String, !subagent.isEmpty { return nil }
        let event = (eventOverride ?? payload["hook_event_name"] as? String ?? payload["type"] as? String ?? "")
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").lowercased()
        let notification = payload["notification_type"] as? String ?? ""
        let tool = (payload["tool_name"] as? String ?? "").lowercased()
        let kind: EventKind
        switch event {
        case "stop", "agentstop", "agentturncomplete": kind = .completed
        case "permissionrequest", "approvalrequested": kind = .approval
        case "stopfailure", "posttoolusefailure": kind = .error
        case "notification":
            switch notification {
            case "permission_prompt": kind = .approval
            case "idle_prompt", "elicitation_dialog": kind = .question
            default: return nil
            }
        case "pretooluse":
            kind = ["askuserquestion", "request_user_input", "userinput", "ask_user"].contains(tool) ? .question : .tool
        default: return nil
        }
        let session = payload["session_id"] as? String ?? payload["thread-id"] as? String
            ?? payload["session_key"] as? String ?? ""
        return AgentEvent(source: source, kind: kind, session: fingerprint(session))
    }
}

public struct Preferences: Codable, Sendable {
    public var paused = false
    public var enabledSources: Set<AgentSource> = Set(AgentSource.allCases)
    public var enabledEvents: Set<EventKind> = [.completed, .approval, .question, .error, .notification]
    public var waveforms: [String: UInt8] = [:]
    public var cooldown: Double = 1.2
    public var crewLogEnabled = true
    public var desktopNotificationsEnabled = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case paused, enabledSources, enabledEvents, waveforms, cooldown, crewLogEnabled, desktopNotificationsEnabled
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
        enabledSources = try values.decodeIfPresent(Set<AgentSource>.self, forKey: .enabledSources) ?? defaults.enabledSources
        enabledEvents = try values.decodeIfPresent(Set<EventKind>.self, forKey: .enabledEvents) ?? defaults.enabledEvents
        waveforms = try values.decodeIfPresent([String: UInt8].self, forKey: .waveforms) ?? defaults.waveforms
        cooldown = try values.decodeIfPresent(Double.self, forKey: .cooldown) ?? defaults.cooldown
        crewLogEnabled = try values.decodeIfPresent(Bool.self, forKey: .crewLogEnabled) ?? defaults.crewLogEnabled
        desktopNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .desktopNotificationsEnabled) ?? true
        // Migrate once. Later app/source toggles remain exactly as the user set them.
        if !values.contains(.desktopNotificationsEnabled) {
            enabledSources.formUnion([.chatgpt, .claudeDesktop]); enabledEvents.insert(.notification)
        }
    }
    public func waveform(for kind: EventKind) -> Waveform {
        waveforms[kind.rawValue].flatMap(Waveform.init(rawValue:)) ?? kind.defaultWaveform
    }
}

public struct EventGate {
    private var previous: [String: Date] = [:]
    private var lastPulse = Date.distantPast
    public init() {}
    public mutating func accepts(_ event: AgentEvent, preferences: Preferences, now: Date = Date()) -> Bool {
        guard !preferences.paused, preferences.enabledSources.contains(event.source),
              preferences.enabledEvents.contains(event.kind),
              now.timeIntervalSince(event.date) < 30, event.date.timeIntervalSince(now) < 5 else { return false }
        let key = "\(event.source.rawValue):\(event.kind.rawValue):\(event.session)"
        let duplicateWindow = event.kind == .approval ? 8.0 : preferences.cooldown
        if let date = previous[key], now.timeIntervalSince(date) < duplicateWindow { return false }
        // An approval can arrive immediately after completion and must still be felt.
        if event.kind == .tool && now.timeIntervalSince(lastPulse) < preferences.cooldown { return false }
        previous = previous.filter { now.timeIntervalSince($0.value) < 30 }
        previous[key] = now; lastPulse = now
        return true
    }
}

public struct LocalStore: Sendable {
    public let root: URL
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["MX_NOTI_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MX Noti")
    }
    public func prepare() throws {
        for url in [root, inbox] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
    public func enqueue(_ event: AgentEvent) throws {
        try prepare()
        let file = inbox.appendingPathComponent(event.id.uuidString + ".json")
        try JSONEncoder().encode(event).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func drain() -> [AgentEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        var events: [AgentEvent] = []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) < 8192,
                  let data = try? Data(contentsOf: file), let event = try? JSONDecoder().decode(AgentEvent.self, from: data) else { continue }
            events.append(event)
        }
        return events.sorted { $0.date < $1.date }
    }
    public func loadPreferences() -> Preferences {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("preferences.json")),
              let p = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return p
    }
    public func save(_ preferences: Preferences) throws {
        try prepare()
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
    }
}
