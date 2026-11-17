import Foundation

// A bounded, rotation-aware tail. Existing bytes are ignored when the app first starts.
final class JSONLineTail {
    let url: URL
    var offset: UInt64 = 0
    var inode: UInt64 = 0
    var pending = Data()
    init(url: URL, startAtEnd: Bool) {
        self.url = url
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if startAtEnd { offset = (attributes[.size] as? NSNumber)?.uint64Value ?? 0 }
        }
    }
    func readLines() -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if number != inode || size < offset { offset = 0; pending.removeAll(); inode = number }
        guard size > offset else { return [] }
        if size - offset > 1_048_576 { offset = size; pending.removeAll(); return [] }
        do {
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: 262_144) ?? Data()
            offset += UInt64(bytes.count); pending.append(bytes)
        } catch { return [] }
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        if pending.count > 262_144 { pending.removeAll() }
        return lines
    }
}

public struct MonitorState: Sendable {
    public var crewFiles = 0
    public var kiroFiles = 0
    public init() {}
}

// All mutable tail state is protected by lock; UI reads receive a value snapshot.
public final class AgentLogMonitor: @unchecked Sendable {
    let home: URL
    private var tails: [String: JSONLineTail] = [:]
    private var kinds: [String: AgentSource] = [:]
    private var nextScan = Date.distantPast
    private var primed = false
    private let lock = NSRecursiveLock()
    private var snapshot = MonitorState()
    public var state: MonitorState { lock.lock(); defer { lock.unlock() }; return snapshot }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func poll() -> [AgentEvent] {
        lock.lock(); defer { lock.unlock() }
        if Date() >= nextScan { discover(); nextScan = Date().addingTimeInterval(4) }
        var events: [AgentEvent] = []
        for (path, tail) in tails {
            for line in tail.readLines() {
                if let event = Self.parse(line: line, source: kinds[path] ?? .custom, identity: tail.url.deletingLastPathComponent().lastPathComponent) {
                    events.append(event)
                }
            }
        }
        return events
    }

    private func discover() {
        let fm = FileManager.default
        var found: [(URL, AgentSource)] = []
        let crew = home.appendingPathComponent(".kiro/crew/crew-log/sessions")
        let sessions = (try? fm.contentsOfDirectory(at: crew, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? []
        for session in sessions {
            guard (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let files = (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("log") && file.pathExtension == "jsonl" { found.append((file, .crew)) }
        }
        let kiroRoot = home.appendingPathComponent("Library/Application Support/Kiro/logs")
        let runs = ((try? fm.contentsOfDirectory(at: kiroRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(2)
        for run in runs {
            let windows = (try? fm.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
            for window in windows where window.lastPathComponent.hasPrefix("window") {
                let file = window.appendingPathComponent("exthost/kiro.kiroAgent/Kiro Logs.log")
                if fm.fileExists(atPath: file.path) { found.append((file, .kiro)) }
            }
        }
        // Keep the most recently used files bounded on machines with a long Crew history.
        found.sort { ((try? $0.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            > ((try? $1.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        found = Array(found.prefix(160))
        let keep = Set(found.map { $0.0.path })
        tails = tails.filter { keep.contains($0.key) }; kinds = kinds.filter { keep.contains($0.key) }
        for (file, source) in found where tails[file.path] == nil {
            tails[file.path] = JSONLineTail(url: file, startAtEnd: !primed)
            kinds[file.path] = source
        }
        primed = true
        snapshot.crewFiles = found.filter { $0.1 == .crew }.count
        snapshot.kiroFiles = found.filter { $0.1 == .kiro }.count
    }

    public static func parse(line: String, source: AgentSource, identity: String, now: Date = Date()) -> AgentEvent? {
        switch source {
        case .crew:
            guard let data = line.data(using: .utf8), let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = row["type"] as? String, let time = row["time"] as? Double else { return nil }
            let kind: EventKind
            switch type {
            case "approval/requested": kind = .approval
            case "turn/completed": kind = .completed
            default: return nil
            }
            let date = Date(timeIntervalSince1970: time / 1000)
            guard abs(now.timeIntervalSince(date)) < 30 else { return nil }
            return AgentEvent(source: .crew, kind: kind, session: AgentEvent.fingerprint(identity), origin: "crew-log", date: date)
        case .kiro:
            guard let range = line.range(of: "agent.pendingInteraction "),
                  let data = String(line[range.upperBound...]).data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row["replay"] as? Bool == false,
                  let type = row["interactionType"] as? String else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            guard let date = formatter.date(from: String(line.prefix(23))), abs(now.timeIntervalSince(date)) < 30 else { return nil }
            let kind: EventKind
            switch type {
            case "tool_approval": kind = .approval
            case "user_question", "question", "user_input": kind = .question
            default: return nil
            }
            let session = row["sessionId"] as? String ?? identity
            return AgentEvent(source: .kiro, kind: kind, session: AgentEvent.fingerprint(session), origin: "kiro-log", date: date)
        default: return nil
        }
    }
}
