import AppKit
import ApplicationServices
import Foundation

public struct DesktopNotice: Sendable {
    public let identity: String
    public let application: String
    public let title: String
    public let body: String
    public let actions: [String]
    public init(identity: String, application: String, title: String, body: String = "", actions: [String] = []) {
        self.identity = identity; self.application = application; self.title = title; self.body = body; self.actions = actions
    }
    public var source: AgentSource? {
        // Match the application field, never an app name mentioned in a message body.
        switch application.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chatgpt", "codex", "com.openai.chat", "com.openai.codex": return .chatgpt
        case "claude", "com.anthropic.claudefordesktop": return .claudeDesktop
        default: return nil
        }
    }
    public var kind: EventKind {
        let actionNames = actions.map { $0.lowercased() }
        if actionNames.contains(where: { ["approve", "allow", "허용", "승인", "허용하기", "승인하기"].contains($0) }) { return .approval }
        let text = (title + "\n" + body).lowercased()
        if ["approval required", "approval requested", "needs your approval", "permission required", "permission request", "승인 요청", "승인이 필요", "허용이 필요", "권한 요청"].contains(where: text.contains) { return .approval }
        if ["needs your input", "waiting for your response", "waiting for input", "질문이 있습니다", "입력 대기", "응답을 기다", "답변이 필요"].contains(where: text.contains) { return .question }
        if ["task failed", "couldn't complete", "작업 실패", "오류 발생"].contains(where: text.contains) { return .error }
        if ["response is ready", "response ready", "task complete", "task is complete", "finished working", "응답 완료", "응답이 준비", "작업 완료", "작업을 완료"].contains(where: text.contains) { return .completed }
        return .notification
    }
    public func event(now: Date = Date()) -> AgentEvent? {
        guard let source else { return nil }
        return AgentEvent(source: source, kind: kind, session: AgentEvent.fingerprint(identity), origin: "macos-banner", date: now)
    }
}

public struct BannerGate {
    private var primed = false
    private var seen: [String: Date] = [:]
    public init() {}
    public mutating func reset() { primed = false; seen.removeAll() }
    public mutating func receive(_ notices: [DesktopNotice], now: Date = Date()) -> [AgentEvent] {
        seen = seen.filter { now.timeIntervalSince($0.value) < 600 }
        var events: [AgentEvent] = []
        for notice in notices {
            if primed && seen[notice.identity] == nil, let event = notice.event(now: now) { events.append(event) }
            seen[notice.identity] = now
        }
        if seen.count > 512 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) }) }
        primed = true
        return events
    }
}

public struct DesktopMonitorState: Codable, Sendable {
    public var accessibilityGranted = false
    public var notificationCenterRunning = false
    public var enabled = false
    public init() {}
}

// Read-only Accessibility access to Notification Center. No clicks, keystrokes,
// notification database access, conversation-window scraping or text persistence.
public final class DesktopNotificationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = BannerGate()
    private var process: pid_t = 0
    private var snapshot = DesktopMonitorState()
    public init() {}
    public var state: DesktopMonitorState { lock.lock(); defer { lock.unlock() }; return snapshot }

    public func poll(enabled: Bool, sources: Set<AgentSource>) -> [AgentEvent] {
        lock.lock(); defer { lock.unlock() }
        snapshot.accessibilityGranted = AXIsProcessTrusted()
        snapshot.enabled = enabled
        guard enabled, snapshot.accessibilityGranted else { gate.reset(); return [] }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            snapshot.notificationCenterRunning = false; process = 0; gate.reset(); return []
        }
        snapshot.notificationCenterRunning = true
        if app.processIdentifier != process { process = app.processIdentifier; gate.reset() }
        let root = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var budget = 240
        let deadline = Date().addingTimeInterval(0.35)
        var notices: [DesktopNotice] = []
        for window in windows {
            Self.collect(window, depth: 0, budget: &budget, deadline: deadline, sources: sources, output: &notices)
        }
        return gate.receive(notices)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String {
        String((attribute(element, name) as? String ?? "").prefix(4096))
    }
    private static func collect(_ element: AXUIElement, depth: Int, budget: inout Int, deadline: Date,
                                sources: Set<AgentSource>, output: inout [DesktopNotice]) {
        guard depth <= 12, budget > 0, Date() < deadline else { return }; budget -= 1
        let identifier = string(element, kAXIdentifierAttribute)
        // The notification-history panel must never produce a new-event alert.
        if identifier == "AXNotificationListItems" || identifier.lowercased().contains("notificationhistory") { return }
        let subrole = string(element, kAXSubroleAttribute)
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if ["AXNotificationCenterBanner", "AXNotificationCenterAlert"].contains(subrole) {
            let description = string(element, kAXDescriptionAttribute)
            let appName = String(description.split(separator: ",", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
            let prototype = DesktopNotice(identity: "", application: appName, title: "")
            guard let source = prototype.source, sources.contains(source) else { return }
            var texts: [String] = [], actions: [String] = []
            for child in children.prefix(24) {
                let role = string(child, kAXRoleAttribute)
                if role == kAXStaticTextRole {
                    let value = string(child, kAXValueAttribute)
                    if !value.isEmpty { texts.append(value) }
                } else if role == kAXButtonRole && string(child, kAXIdentifierAttribute) == "action_button" {
                    actions.append(string(child, kAXTitleAttribute))
                }
            }
            let title = texts.first ?? ""
            let body = texts.isEmpty ? String(description.dropFirst(appName.count)) : texts.dropFirst().joined(separator: "\n")
            let identity = "\(processID(element)):\(CFHash(element)):\(AgentEvent.fingerprint(description))"
            output.append(DesktopNotice(identity: identity, application: appName, title: title, body: body, actions: actions))
            return
        }
        for child in children { collect(child, depth: depth + 1, budget: &budget, deadline: deadline, sources: sources, output: &output) }
    }
    private static func processID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return pid
    }
}
