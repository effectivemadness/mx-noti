import Foundation
import Darwin

public struct IntegrationChange: Codable, Sendable {
    public let path: String
    public let changed: Bool
    public let backup: String?
}

public struct IntegrationInstaller: Sendable {
    public let home: URL
    public let executable: URL
    private static let marker = "# mx-noti-managed"
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: URL) {
        self.home = home; self.executable = executable
    }
    private func command(_ source: AgentSource, event: String? = nil) -> String {
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + " --hook " + source.rawValue + (event.map { " --event " + $0 } ?? "") + " " + Self.marker
    }
    private func owned(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.hasSuffix(Self.marker) == true
    }
    public func isInstalled(_ source: AgentSource) -> Bool {
        let path: String
        switch source {
        case .claude: path = ".claude/settings.json"
        case .codex: path = ".codex/hooks.json"
        case .kiro: path = ".kiro/hooks/mx-noti.json"
        case .crew, .chatgpt, .claudeDesktop, .custom: return false
        }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(path)),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(Self.marker)
    }

    @discardableResult public func install(_ source: AgentSource, remove: Bool = false) throws -> IntegrationChange {
        switch source {
        case .claude, .codex:
            let path = source == .claude ? ".claude/settings.json" : ".codex/hooks.json"
            return try modify(home.appendingPathComponent(path)) { root in
                if let hooks = root["hooks"], !(hooks is [String: Any]) { throw HIDFailure.message("기존 hooks 설정이 올바른 JSON 객체가 아니어서 보존했습니다.") }
                var hooks = root["hooks"] as? [String: Any] ?? [:]
                for key in Array(hooks.keys) {
                    guard let groups = hooks[key] as? [[String: Any]] else { continue }
                    let retainedGroups = groups.compactMap { group -> [String: Any]? in
                        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                        let retained = handlers.filter { !owned($0) }
                        if retained.count == handlers.count { return group }
                        guard !retained.isEmpty else { return nil }
                        var edited = group; edited["hooks"] = retained; return edited
                    }
                    if retainedGroups.isEmpty && !groups.isEmpty { hooks.removeValue(forKey: key) }
                    else { hooks[key] = retainedGroups }
                }
                if !remove {
                    var events: [(String, String?)] = [("Stop", nil)]
                    if source == .claude {
                        events += [("PermissionRequest", nil), ("Notification", "idle_prompt|elicitation_dialog"), ("PreToolUse", "AskUserQuestion"), ("StopFailure", nil)]
                    } else { events += [("PreToolUse", ".*request_user_input.*")] }
                    for (event, matcher) in events {
                        if let groups = hooks[event], !(groups is [[String: Any]]) { throw HIDFailure.message("기존 \(event) 훅 구조를 변경할 수 없어 중단했습니다.") }
                        var groups = hooks[event] as? [[String: Any]] ?? []
                        var group: [String: Any] = ["hooks": [["type": "command", "command": command(source), "timeout": 3]]]
                        if let matcher { group["matcher"] = matcher }
                        groups.append(group); hooks[event] = groups
                    }
                }
                root["hooks"] = hooks
            }
        case .kiro: return try installKiro(directory: home, remove: remove)
        default: throw HIDFailure.message("Kiro Crew는 실행 중 로컬 이벤트를 자동으로 감지합니다.")
        }
    }

    @discardableResult public func installKiro(directory: URL, remove: Bool = false) throws -> IntegrationChange {
        try modify(directory.appendingPathComponent(".kiro/hooks/mx-noti.json")) { root in
            if let version = root["version"] as? String, version != "v1" { throw HIDFailure.message("지원하지 않는 기존 Kiro 훅 버전이라 변경하지 않았습니다.") }
            if let entries = root["hooks"], !(entries is [[String: Any]]) { throw HIDFailure.message("기존 Kiro 훅 구조를 보존하기 위해 중단했습니다.") }
            var entries = root["hooks"] as? [[String: Any]] ?? []
            entries.removeAll { (($0["name"] as? String)?.hasPrefix("mx-noti-") ?? false)
                && (($0["action"] as? [String: Any]).map(owned) ?? false) }
            if !remove {
                for event in ["Stop", "PreToolUse"] {
                    entries.append(["name": "mx-noti-" + event.lowercased(), "description": "MX Noti 햅틱 알림", "trigger": event,
                        "action": ["type": "command", "command": command(.kiro, event: event)], "timeout": 3, "enabled": true])
                }
            }
            root["version"] = root["version"] ?? "v1"; root["hooks"] = entries
        }
    }

    private func modify(_ url: URL, transform: (inout [String: Any]) throws -> Void) throws -> IntegrationChange {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = url.path + ".mx-noti.lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HIDFailure.message("설정 파일 잠금을 만들 수 없습니다: " + url.path) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HIDFailure.message("다른 MX Noti가 설정을 변경 중입니다. 잠시 후 다시 시도해주세요.") }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw HIDFailure.message("연결된 설정 파일은 자동 변경하지 않습니다: " + url.path)
        }
        let exists = fm.fileExists(atPath: url.path)
        let original = exists ? try Data(contentsOf: url) : nil
        var root: [String: Any] = [:]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw HIDFailure.message("기존 설정이 JSON 객체가 아니어서 변경하지 않았습니다: " + url.path)
            }
            root = object
        }
        let before = root as NSDictionary
        try transform(&root)
        if before.isEqual(to: root) { return IntegrationChange(path: url.path, changed: false, backup: nil) }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw HIDFailure.message("설정 파일이 다른 앱에서 변경되었습니다. 다시 시도해주세요.") }
        var backup: String?
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        if let original {
            let target = url.appendingPathExtension("mx-noti-backup-" + UUID().uuidString)
            try original.write(to: target, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            backup = target.path
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return IntegrationChange(path: url.path, changed: true, backup: backup)
    }
}
