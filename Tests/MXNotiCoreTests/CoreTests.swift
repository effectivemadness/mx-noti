import XCTest
@testable import MXNotiCore

final class CoreTests: XCTestCase {
    func testHIDFiltersOtherClientsAndAcceptsBluetoothSlotZero() throws {
        let p = HIDProtocol.packet(feature: 9, function: 4, parameters: [12])
        XCTAssertEqual(p.count, 20)
        XCTAssertEqual(Array(p.prefix(5)), [0x11, 0xFF, 9, 0x4D, 12])
        XCTAssertNil(try HIDProtocol.reply([0x11, 0, 9, 0x41, 0, 0, 0], for: p))
        XCTAssertEqual(try HIDProtocol.reply([0x11, 0, 9, 0x4D, 12, 0, 0], for: p), [12, 0, 0])
        XCTAssertThrowsError(try HIDProtocol.reply([0x11, 0, 0xFF, 9, 0x4D, 8, 0], for: p))
        XCTAssertNil(try HIDProtocol.reply([0x11, 0, 0xFF, 9, 0x41, 8, 0], for: p))
    }
    func testCapabilityBitmapUsesBigEndianAndRejectsTruncatedReply() throws {
        XCTAssertEqual(try HIDProtocol.supportedWaveforms([0, 0, 0, 0, 8, 0, 0x10, 0x80]), [7, 12, 27])
        XCTAssertThrowsError(try HIDProtocol.supportedWaveforms([0, 0]))
    }
    func testHookClassificationAvoidsGenericNotificationsAndSubagents() {
        XCTAssertEqual(AgentEvent.fromHook(source: .claude, payload: ["hook_event_name": "PermissionRequest"])?.kind, .approval)
        XCTAssertEqual(AgentEvent.fromHook(source: .kiro, payload: ["hook_event_name": "stop"])?.kind, .completed)
        XCTAssertEqual(AgentEvent.fromHook(source: .codex, payload: ["type": "agent-turn-complete"])?.kind, .completed)
        XCTAssertNil(AgentEvent.fromHook(source: .claude, payload: ["hook_event_name": "Notification", "notification_type": "auth_success"]))
        XCTAssertNil(AgentEvent.fromHook(source: .crew, payload: ["hook_event_name": "Stop", "subagent_id": "child"]))
        XCTAssertEqual(AgentEvent.fromHook(source: .claude, payload: ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"])?.kind, .question)
    }
    func testApprovalDeduplicationNeverSuppressesAnotherSession() {
        let now = Date()
        var gate = EventGate(); let p = Preferences()
        let first = AgentEvent(source: .claude, kind: .approval, session: "one", date: now)
        XCTAssertTrue(gate.accepts(first, preferences: p, now: now))
        XCTAssertFalse(gate.accepts(first, preferences: p, now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.accepts(AgentEvent(source: .claude, kind: .approval, session: "two", date: now), preferences: p, now: now))
        XCTAssertFalse(gate.accepts(AgentEvent(source: .claude, kind: .completed, date: now.addingTimeInterval(-31)), preferences: p, now: now))
        XCTAssertFalse(gate.accepts(AgentEvent(source: .kiro, kind: .tool, date: now), preferences: p, now: now))
    }
    func testSpoolPreservesConcurrentEventsAndNeverStoresPromptText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        let event = try XCTUnwrap(AgentEvent.fromHook(source: .claude, payload: ["hook_event_name": "Stop", "session_id": "private-session", "prompt": "secret prompt", "assistant_response": "secret reply"]))
        try store.enqueue(event); try store.enqueue(AgentEvent(source: .codex, kind: .approval))
        let data = try Data(contentsOf: store.inbox.appendingPathComponent(event.id.uuidString + ".json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-session")); XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(store.drain().count, 2); XCTAssertEqual(store.drain().count, 0)
    }

    func testInstallerPreservesForeignHooksIsIdempotentAndBacksUpExactBytes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-notifier"}]}]}}"#.utf8)
        try original.write(to: url)
        let installer = IntegrationInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/with 'quotes'/MX Noti.app/Contents/MacOS/MXNoti"))
        let result = try installer.install(.claude)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.backup))), original)
        XCTAssertFalse(try installer.install(.claude).changed)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("existing-notifier"))
        _ = try installer.install(.claude, remove: true)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(root, try JSONSerialization.jsonObject(with: original) as? NSDictionary)
    }
    func testInstallerRefusesMalformedSettingsWithoutOverwritingThem() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not JSON".utf8); try original.write(to: url)
        let installer = IntegrationInstaller(home: home, executable: URL(fileURLWithPath: "/tmp/MXNoti"))
        XCTAssertThrowsError(try installer.install(.codex))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testLogAdaptersIgnoreReplaysHistoryAndUnrelatedToolCalls() {
        let now = Date()
        let old = #"{"type":"approval/requested","time":1,"data":{}}"#
        XCTAssertNil(AgentLogMonitor.parse(line: old, source: .crew, identity: "session", now: now))
        let current = "{\"type\":\"approval/requested\",\"time\":\(now.timeIntervalSince1970 * 1000),\"data\":{\"reason\":\"private command\"}}"
        XCTAssertEqual(AgentLogMonitor.parse(line: current, source: .crew, identity: "session", now: now)?.kind, .approval)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let replay = formatter.string(from: now) + #" [info] [PermTrace] agent.pendingInteraction {"interactionType":"tool_approval","replay":true,"sessionId":"s"}"#
        XCTAssertNil(AgentLogMonitor.parse(line: replay, source: .kiro, identity: "window", now: now))
        XCTAssertEqual(AgentLogMonitor.parse(line: replay.replacingOccurrences(of: ":true", with: ":false"), source: .kiro, identity: "window", now: now)?.kind, .approval)
    }
    func testTailKeepsPartialLinesAndHandlesReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        try Data("old\n".utf8).write(to: url)
        let tail = JSONLineTail(url: url, startAtEnd: true)
        XCTAssertEqual(tail.readLines(), [])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("par".utf8))
        XCTAssertEqual(tail.readLines(), [])
        try handle.write(contentsOf: Data("tial\nsecond\n".utf8)); try handle.close()
        XCTAssertEqual(tail.readLines(), ["partial", "second"])
        try Data("rotated\n".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(tail.readLines(), ["rotated"])
    }

    func testDesktopNotificationSourceCannotBeSpoofedByMentioningAppInBody() {
        XCTAssertNil(DesktopNotice(identity: "1", application: "Messages", title: "ChatGPT response is ready", body: "Claude task complete").event())
        XCTAssertEqual(DesktopNotice(identity: "2", application: "ChatGPT", title: "Response is ready").event()?.source, .chatgpt)
        XCTAssertEqual(DesktopNotice(identity: "3", application: "com.anthropic.claudefordesktop", title: "Task complete").event()?.source, .claudeDesktop)
        XCTAssertNil(DesktopNotice(identity: "4", application: "ChatGPT Helper", title: "Done").event())
    }
    func testDesktopNoticeClassifiesAttentionAndKeepsUnknownAlertsGeneric() {
        XCTAssertEqual(DesktopNotice(identity: "1", application: "ChatGPT", title: "Needs your approval").kind, .approval)
        XCTAssertEqual(DesktopNotice(identity: "2", application: "Claude", title: "승인이 필요합니다").kind, .approval)
        XCTAssertEqual(DesktopNotice(identity: "3", application: "Claude", title: "Tool", actions: ["Allow"]).kind, .approval)
        XCTAssertEqual(DesktopNotice(identity: "4", application: "ChatGPT", title: "Waiting for your response").kind, .question)
        XCTAssertEqual(DesktopNotice(identity: "5", application: "Claude", title: "Task complete").kind, .completed)
        XCTAssertEqual(DesktopNotice(identity: "6", application: "ChatGPT", title: "새 메시지").kind, .notification)
    }
    func testNotificationBannerBaselineAndTemporaryDisappearanceDoNotReplay() {
        var gate = BannerGate()
        let old = DesktopNotice(identity: "old", application: "ChatGPT", title: "Task complete")
        let fresh = DesktopNotice(identity: "fresh", application: "Claude", title: "Needs your approval")
        XCTAssertTrue(gate.receive([old]).isEmpty)
        XCTAssertEqual(gate.receive([old, fresh]).map(\.kind), [.approval])
        XCTAssertTrue(gate.receive([]).isEmpty)
        XCTAssertTrue(gate.receive([fresh]).isEmpty)
        gate.reset()
        XCTAssertTrue(gate.receive([fresh]).isEmpty)
    }
    func testDesktopEventsPersistOnlyMetadata() throws {
        let notice = DesktopNotice(identity: "private-notification-id", application: "Claude", title: "Private conversation", body: "Private reply content")
        let event = try XCTUnwrap(notice.event())
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains("Private")); XCTAssertFalse(text.contains("private-notification-id"))
        XCTAssertEqual(event.origin, "macos-banner")
    }
    func testPreferencesMigrationPreservesSettingsAndOptOuts() throws {
        let legacy = Data(#"{"paused":true,"enabledSources":["codex"],"enabledEvents":["approval"],"waveforms":{"approval":8},"cooldown":2,"crewLogEnabled":false}"#.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertTrue(preferences.paused); XCTAssertFalse(preferences.crewLogEnabled)
        XCTAssertEqual(preferences.waveform(for: .approval), .square)
        XCTAssertEqual(preferences.enabledSources, [.codex, .chatgpt, .claudeDesktop])
        XCTAssertEqual(preferences.enabledEvents, [.approval, .notification])
        preferences.enabledSources.remove(.claudeDesktop); preferences.desktopNotificationsEnabled = false
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(restored.enabledSources.contains(.claudeDesktop)); XCTAssertFalse(restored.desktopNotificationsEnabled)
    }
}
