import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement
import SwiftUI
import MXNotiCore

@MainActor final class AppModel: ObservableObject {
    @Published var preferences: Preferences { didSet { try? store.save(preferences) } }
    @Published var mouse: MouseStatus?
    @Published var deviceMessage = "마우스 연결 확인 중"
    @Published var checking = false
    @Published var activity: [Activity] = []
    @Published var installed: Set<AgentSource> = []
    @Published var monitorState = MonitorState()
    @Published var desktopState = DesktopMonitorState()
    @Published var notice: String?
    @Published var working = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private let store = LocalStore()
    private let worker = DispatchQueue(label: "app.mx-noti.hardware", qos: .userInitiated)
    private let monitor = AgentLogMonitor()
    private let desktopWorker = DispatchQueue(label: "app.mx-noti.desktop-notifications", qos: .utility)
    private let desktopMonitor = DesktopNotificationMonitor()
    private var gate = EventGate()
    private var timer: Timer?
    private var ticks = 0
    private var pendingPulses = 0
    private var polling = false
    private var desktopPolling = false

    struct Activity: Identifiable {
        let id = UUID()
        let event: AgentEvent
        var result: String
    }
    var installer: IntegrationInstaller {
        IntegrationInstaller(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }
    var ready: Bool { mouse?.enabled == true }
    init() {
        preferences = store.loadPreferences()
        try? store.prepare()
        refreshIntegrations(); refreshDevice(); poll(); pollDesktop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.poll(); self.pollDesktop(); self.ticks += 1
                if self.ticks % 40 == 0 { self.refreshDevice(); self.refreshIntegrations() }
            }
        }
    }
    func refreshIntegrations() {
        installed = Set([AgentSource.claude, .codex, .kiro].filter { installer.isInstalled($0) })
    }
    func refreshDevice() {
        guard !checking else { return }; checking = true
        worker.async {
            let result = Result { try Haptics.status() }
            DispatchQueue.main.async {
                self.checking = false
                switch result {
                case .success(let status):
                    self.mouse = status
                    self.deviceMessage = status.enabled ? "Bluetooth 연결됨 · 햅틱 세기 \(status.level)%" : "Logi Options+에서 햅틱을 활성화하세요."
                case .failure(let error): self.mouse = nil; self.deviceMessage = error.localizedDescription
                }
            }
        }
    }
    func requestMouseAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }
    func requestNotificationAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func pollDesktop() {
        guard !desktopPolling else { return }; desktopPolling = true
        let enabled = preferences.desktopNotificationsEnabled
        let sources = preferences.enabledSources
        desktopWorker.async {
            let events = self.desktopMonitor.poll(enabled: enabled, sources: sources)
            let state = self.desktopMonitor.state
            DispatchQueue.main.async {
                self.desktopPolling = false; self.desktopState = state
                for event in events { self.receive(event) }
            }
        }
    }
    private func poll() {
        guard !polling else { return }; polling = true
        let logEnabled = preferences.crewLogEnabled
        worker.async {
            var events = self.store.drain()
            let logEvents = self.monitor.poll()
            if logEnabled { events += logEvents }
            let state = self.monitor.state
            DispatchQueue.main.async {
                self.polling = false; self.monitorState = state
                for event in events { self.receive(event) }
            }
        }
    }
    private func receive(_ event: AgentEvent) {
        guard gate.accepts(event, preferences: preferences) else { return }
        pulse(event: event, waveform: preferences.waveform(for: event.kind))
    }
    func test(_ kind: EventKind) {
        pulse(event: AgentEvent(source: .custom, kind: kind, origin: "preview"), waveform: preferences.waveform(for: kind))
    }
    private func pulse(event: AgentEvent, waveform: Waveform) {
        guard pendingPulses < 4 else { return }; pendingPulses += 1
        let item = Activity(event: event, result: "전송 중")
        activity.insert(item, at: 0); activity = Array(activity.prefix(40))
        worker.async {
            let result = Result { try Haptics.play(waveform) }
            DispatchQueue.main.async {
                self.pendingPulses -= 1
                switch result {
                case .success(let status):
                    self.mouse = status
                    self.deviceMessage = "Bluetooth 연결됨 · 햅틱 세기 \(status.level)%"
                case .failure(let error): self.mouse = nil; self.deviceMessage = error.localizedDescription
                }
                if let index = self.activity.firstIndex(where: { $0.id == item.id }) {
                    self.activity[index].result = (try? result.get()) != nil ? "전송 완료" : "연결 확인 필요"
                }
                self.writeRuntimeState()
            }
        }
    }
    private func writeRuntimeState() {
        let rows: [[String: Any]] = activity.prefix(10).map {
            ["source": $0.event.source.rawValue, "event": $0.event.kind.rawValue, "origin": $0.event.origin,
             "time": $0.event.date.timeIntervalSince1970, "result": $0.result]
        }
        let state: [String: Any] = ["connected": ready, "updated": Date().timeIntervalSince1970, "events": rows]
        if let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? bytes.write(to: store.root.appendingPathComponent("status.json"), options: .atomic)
        }
    }
    func install(_ source: AgentSource, remove: Bool = false) {
        working = true; let installer = self.installer
        worker.async {
            let result = Result { try installer.install(source, remove: remove) }
            DispatchQueue.main.async {
                self.working = false; self.refreshIntegrations()
                switch result {
                case .success:
                    self.notice = remove ? "\(source.title) 연결을 해제했습니다. 기존 훅은 보존했습니다." :
                        source == .codex ? "Codex 연결을 추가했습니다. 새 세션에서 설정 → Hooks 또는 /hooks를 열어 MX Noti 훅을 검토하고 허용하세요." :
                        source == .kiro ? "Kiro CLI 전역 연결을 추가했습니다. IDE는 프로젝트 폴더 연결이 필요합니다." : "\(source.title) 연결을 추가했습니다. 새 세션부터 적용됩니다."
                case .failure(let error): self.notice = error.localizedDescription
                }
            }
        }
    }
    func connectKiroProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "프로젝트 연결"; panel.message = "Kiro IDE에서 사용하는 프로젝트 폴더를 선택하세요."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            _ = try installer.installKiro(directory: directory)
            notice = "\(directory.lastPathComponent) 프로젝트를 연결했습니다. Kiro의 새 세션에서 완료 알림이 적용됩니다."
        } catch { notice = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { notice = "시스템 설정 → 일반 → 로그인 항목에서 MX Noti를 허용하세요." }
        } catch { loginEnabled = false; notice = error.localizedDescription }
    }
}

struct MXNotiApplication: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("MX Noti", id: "settings") { Dashboard(model: model).frame(minWidth: 820, minHeight: 720) }
            .defaultSize(width: 860, height: 750).windowResizability(.contentMinSize)
        MenuBarExtra("MX Noti", systemImage: model.preferences.paused ? "waveform.slash" : "waveform") {
            Text(model.ready ? "MX Master 4 · 연결됨" : "MX Master 4 · 연결 확인 필요")
            Toggle("알림 일시 정지", isOn: $model.preferences.paused)
            Divider()
            Button("완료 진동 테스트") { model.test(.completed) }
            Button("승인 진동 테스트") { model.test(.approval) }
            Divider()
            Button("MX Noti 열기…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
            Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

private enum Design {
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.17)
    static let accent = Color(red: 0.16, green: 0.41, blue: 0.33)
    static let muted = Color(red: 0.44, green: 0.49, blue: 0.46)
    static let canvas = Color(red: 0.97, green: 0.97, blue: 0.94)
    static let line = Color(red: 0.88, green: 0.90, blue: 0.86)
}

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @State private var page = 0
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if page == 0 { notifications }
                    else if page == 1 { connections }
                    else { recentActivity }
                }.padding(32).frame(maxWidth: 760, alignment: .leading)
            }.background(Design.canvas)
        }.foregroundStyle(Design.ink).tint(Design.accent)
            .alert("MX Noti", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("확인", role: .cancel) { model.notice = nil }
            } message: { Text(model.notice ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .medium)).foregroundStyle(Design.accent)
                Text("MX Noti").font(.system(size: 22, weight: .semibold, design: .rounded))
            }.padding(.top, 12)
            VStack(spacing: 7) {
                nav("햅틱 알림 설정", symbol: "waveform.path", index: 0)
                nav("앱 연결", symbol: "point.3.connected.trianglepath.dotted", index: 1)
                nav("알림 기록", symbol: "clock", index: 2)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("로컬 처리", systemImage: "lock.shield").font(.system(size: 12, weight: .medium))
                Text("대화 내용 저장 안 함").font(.system(size: 11)).foregroundStyle(Design.muted)
                Text("MX MASTER 4  /  v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Design.muted).padding(.top, 10)
            }
        }.padding(22).frame(width: 170).frame(maxHeight: .infinity).background(.white)
            .overlay(alignment: .trailing) { Rectangle().fill(Design.line).frame(width: 1) }
    }
    private func nav(_ label: String, symbol: String, index: Int) -> some View {
        Button { page = index } label: {
            Label(label, systemImage: symbol).font(.system(size: 13, weight: page == index ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                .background(page == index ? Design.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(page == index ? Design.accent : Design.muted)
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(["햅틱 알림 설정", "앱 연결 설정", "최근 알림 기록"][page])
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(["이벤트별 알림 사용 여부와 진동 패턴을 설정합니다.", "앱별 연결 상태와 알림 사용 여부를 설정합니다.", "앱 실행 중 수신한 알림과 진동 전송 결과를 표시합니다."][page])
                    .font(.system(size: 12)).foregroundStyle(Design.muted)
            }
            Spacer(minLength: 8)
            Button { model.preferences.paused.toggle() } label: {
                Image(systemName: model.preferences.paused ? "play.fill" : "pause.fill").frame(width: 30, height: 30)
            }.buttonStyle(.bordered).help(model.preferences.paused ? "알림 재개" : "알림 일시 정지")
        }
    }
    private var deviceCard: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "computermouse.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Design.accent)
                .frame(width: 60, height: 70).background(Design.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("MX Master 4").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Circle().fill(model.ready ? Design.accent : Color.orange).frame(width: 7, height: 7)
                    Text(model.ready ? (model.preferences.paused ? "일시 정지" : "준비됨") : "연결 확인").font(.system(size: 11, weight: .medium))
                }
                Text(model.deviceMessage).font(.system(size: 11)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.checking ? "확인 중…" : "다시 연결") { model.refreshDevice() }.disabled(model.checking)
                    if !model.ready { Button("마우스 접근 허용") { model.requestMouseAccess() } }
                }.font(.system(size: 11)).buttonStyle(.borderless)
            }.padding(.vertical, 3)
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).stroke(Design.line, lineWidth: 1) }
    }
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 20) {
            deviceCard
            if model.preferences.paused {
                Label("알림 일시 정지 중", systemImage: "pause.circle")
                    .font(.system(size: 12)).foregroundStyle(Design.muted)
            }
            HStack { sectionLabel("이벤트별 알림"); Spacer(); Text("▶ 진동 테스트").font(.system(size: 10)).foregroundStyle(Design.muted) }
            VStack(spacing: 0) {
                ForEach(EventKind.allCases) { kind in
                    eventRow(kind)
                    if kind != EventKind.allCases.last { Divider().padding(.leading, 18) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Design.line, lineWidth: 1) }
            Text("진동 세기는 Logi Options+ 설정을 따릅니다.")
                .font(.system(size: 11)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
            Button { page = 1 } label: { Label("앱 연결 설정", systemImage: "arrow.right.circle") }.buttonStyle(.borderless)
        }
    }
    private func eventRow(_ kind: EventKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 16)).foregroundStyle(kind == .approval ? Color(red: 0.75, green: 0.44, blue: 0.20) : Design.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
                if kind == .tool { Text("Kiro · 모든 도구 호출에 적용").font(.system(size: 9)).foregroundStyle(Design.muted) }
            }.frame(minWidth: 95, alignment: .leading)
            Spacer(minLength: 0)
            Picker("\(kind.title) 진동 패턴", selection: Binding(get: { model.preferences.waveform(for: kind).rawValue }, set: { model.preferences.waveforms[kind.rawValue] = $0 })) {
                ForEach(Waveform.allCases) { waveform in Text(waveform.title).tag(waveform.rawValue) }
            }.labelsHidden().frame(width: 110)
            Button { model.test(kind) } label: { Image(systemName: "play.fill").font(.system(size: 10)).frame(width: 22, height: 24) }
                .buttonStyle(.borderless).help("\(kind.title) 진동 테스트")
            Toggle(kind.title, isOn: Binding(get: { model.preferences.enabledEvents.contains(kind) }, set: {
                if $0 { model.preferences.enabledEvents.insert(kind) } else { model.preferences.enabledEvents.remove(kind) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 18).padding(.vertical, 17)
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionLabel("데스크톱 앱 알림")
                    Spacer()
                    Toggle("데스크톱 앱 알림 감지", isOn: $model.preferences.desktopNotificationsEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text("ChatGPT·Claude가 표시하는 macOS 알림 배너를 진동으로 전달합니다. 앱의 알림 설정과 macOS 배너 알림이 켜져 있어야 합니다.")
                    .font(.system(size: 11)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label(model.desktopState.accessibilityGranted ? "손쉬운 사용 권한 허용됨" : "손쉬운 사용 권한 필요", systemImage: model.desktopState.accessibilityGranted ? "checkmark.circle" : "lock")
                        .font(.system(size: 11)).foregroundStyle(Design.muted)
                    Spacer()
                    if !model.desktopState.accessibilityGranted { Button("알림 감지 권한 설정") { model.requestNotificationAccess() }.buttonStyle(.bordered) }
                }
            }
            VStack(spacing: 0) {
                sourceRow(.chatgpt)
                Divider().padding(.leading, 18)
                sourceRow(.claudeDesktop)
            }.background(.white, in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Design.line, lineWidth: 1) }
            Text("배너가 표시되지 않는 응답은 감지하지 못합니다. 알림 문구로 종류를 구분하며, 구분할 수 없는 경우 ‘앱 알림’ 패턴을 사용합니다.")
                .font(.system(size: 11)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
            sectionLabel("에이전트 도구 연결")
            VStack(spacing: 0) {
                ForEach([AgentSource.claude, .codex, .kiro, .crew], id: \.self) { source in
                    sourceRow(source)
                    if source != .crew { Divider().padding(.leading, 18) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Design.line, lineWidth: 1) }
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Kiro IDE 프로젝트")
                Text("완료 알림은 프로젝트별로 연결해야 합니다. 승인 요청은 로컬 이벤트에서 자동 감지합니다.")
                    .font(.system(size: 12)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
                Button("프로젝트 폴더 연결…") { model.connectKiroProject() }.buttonStyle(.bordered)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Design.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            Toggle("로그인할 때 MX Noti 실행", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            Text("연결 시 원본 설정을 백업합니다. Claude Code는 새 세션부터, Codex는 새 훅 검토·허용 후 적용됩니다. Kiro·Crew의 로그 기반 감지는 앱 버전에 따라 달라질 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func sourceRow(_ source: AgentSource) -> some View {
        HStack(spacing: 12) {
            Text(sourceBadge(source))
                .font(.system(size: [.crew, .chatgpt].contains(source) ? 12 : 20, weight: .semibold, design: .rounded)).foregroundStyle(Design.accent)
                .frame(width: 40, height: 40).background(Design.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(source.title).font(.system(size: 13, weight: .medium))
                Text(sourceDetail(source))
                    .font(.system(size: 10)).foregroundStyle(Design.muted)
            }
            Spacer()
            if [.claude, .codex, .kiro].contains(source) {
                Menu {
                    Button(model.installed.contains(source) ? "연결 갱신" : "연결하기") { model.install(source) }
                    if model.installed.contains(source) { Button("연결 해제") { model.install(source, remove: true) } }
                } label: { Text(model.installed.contains(source) ? "연결됨" : "연결").font(.system(size: 11)) }
                    .fixedSize().disabled(model.working)
            }
            Toggle(source.title, isOn: Binding(get: { model.preferences.enabledSources.contains(source) }, set: {
                if $0 { model.preferences.enabledSources.insert(source) } else { model.preferences.enabledSources.remove(source) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(18)
    }
    private func sourceBadge(_ source: AgentSource) -> String {
        switch source {
        case .chatgpt: return "GPT"
        case .claudeDesktop: return "C"
        case .claude: return "✳"
        case .codex: return "⌘"
        case .kiro: return "K"
        case .crew: return "KC"
        case .custom: return "＋"
        }
    }
    private func sourceDetail(_ source: AgentSource) -> String {
        switch source {
        case .chatgpt, .claudeDesktop:
            if !model.preferences.desktopNotificationsEnabled { return "앱 알림 감지 꺼짐" }
            return model.desktopState.accessibilityGranted ? "macOS 알림 배너 감지" : "손쉬운 사용 권한 필요"
        case .crew: return model.monitorState.crewFiles > 0 ? "로컬 완료·승인 이벤트 자동 감지" : "Crew 이벤트 기록 없음"
        case .kiro: return model.installed.contains(source) ? "CLI 연결됨 · IDE는 프로젝트별 연결" : "CLI 전역 훅 · IDE 프로젝트 훅"
        case .codex: return model.installed.contains(source) ? "CLI · 데스크톱 Codex 작업 훅 설정됨" : "CLI · 데스크톱 Codex 작업 훅"
        default: return model.installed.contains(source) ? "훅 설정됨 · 새 세션에서 적용" : "완료 · 승인 요청 · 입력 대기"
        }
    }
    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 18) {
            deviceCard
            if model.activity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Design.accent.opacity(0.6))
                    Text("알림 기록 없음").font(.system(size: 14, weight: .medium))
                    Text("진동 테스트와 연결된 앱의 알림이 여기에 표시됩니다.").font(.system(size: 11)).foregroundStyle(Design.muted)
                    Button("완료 진동 테스트") { model.test(.completed) }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                ForEach(model.activity) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.event.kind.symbol).foregroundStyle(Design.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.event.source.title) · \(item.event.kind.title)").font(.system(size: 12, weight: .medium))
                            Text(item.result).font(.system(size: 10)).foregroundStyle(Design.muted)
                        }
                        Spacer()
                        Text(item.event.date, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(Design.muted)
                    }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 13, weight: .semibold)) }
}
