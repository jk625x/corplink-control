import AppKit
import Combine
import ServiceManagement
import SwiftUI

private enum AppConstants {
  static let languageKey = "appLanguage"
  static let keepRunningKey = "keepRunningAfterWindowClose"
  static let serviceLabel = "com.volcengine.corplink.service"
  static let plistPath = "/Library/LaunchDaemons/com.volcengine.corplink.service.plist"
  static let executablePath = "/usr/local/corplink/corplink-service"
  static let cliPath = "/usr/local/corplink/corplink-cli"
  static let repositoryURL = URL(string: "https://github.com/jk625x/corplink-control")!
}

private enum AppLanguage: String, CaseIterable, Identifiable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  var id: String { rawValue }
  var displayName: String {
    switch self {
    case .english: return "English"
    case .simplifiedChinese: return "简体中文"
    }
  }

  var helperCode: String { rawValue }
}

private func text(_ language: AppLanguage, _ english: String, _ chinese: String) -> String {
  language == .simplifiedChinese ? chinese : english
}

private enum ServiceState: Equatable {
  case loading
  case running([Int32])
  case stopped
  case inconsistent(loaded: Bool, pids: [Int32])

  func title(_ language: AppLanguage) -> String {
    switch self {
    case .loading: return text(language, "Checking…", "正在检查…")
    case .running: return text(language, "Corplink connection service is running", "飞连连接服务正在运行")
    case .stopped: return text(language, "Corplink connection service is stopped", "飞连连接服务已停止")
    case .inconsistent: return text(language, "Connection service state is inconsistent", "连接服务状态异常")
    }
  }

  func detail(_ language: AppLanguage) -> String {
    switch self {
    case .loading: return ""
    case .running(let pids): return "PID \(pids.map(String.init).joined(separator: ", "))"
    case .stopped: return text(language, "Not loaded, with no remaining process", "未加载，且没有残留进程")
    case .inconsistent(let loaded, let pids):
      let processText =
        pids.isEmpty
        ? text(language, "No process", "无进程")
        : "PID \(pids.map(String.init).joined(separator: ", "))"
      return "system domain \(loaded ? text(language, "loaded", "已加载") : text(language, "not loaded", "未加载")) · \(processText)"
    }
  }

  var symbol: String {
    switch self {
    case .loading: return "arrow.clockwise"
    case .running: return "checkmark.shield.fill"
    case .stopped: return "shield.slash"
    case .inconsistent: return "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch self {
    case .loading: return .secondary
    case .running: return .green
    case .stopped: return .secondary
    case .inconsistent: return .orange
    }
  }

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  var isStopped: Bool { self == .stopped }

  var isLoading: Bool { self == .loading }

  func domainText(_ language: AppLanguage) -> String {
    switch self {
    case .loading: return text(language, "Checking", "检查中")
    case .running: return text(language, "Loaded", "已加载")
    case .stopped: return text(language, "Not loaded", "未加载")
    case .inconsistent(let loaded, _):
      return loaded ? text(language, "Loaded", "已加载") : text(language, "Not loaded", "未加载")
    }
  }

  func pidText(_ language: AppLanguage) -> String {
    switch self {
    case .running(let pids), .inconsistent(_, let pids):
      return pids.isEmpty ? text(language, "None", "无") : pids.map(String.init).joined(separator: ", ")
    case .loading: return text(language, "Checking", "检查中")
    case .stopped: return text(language, "None", "无")
    }
  }
}

private struct ComponentStatus: Identifiable, Equatable {
  let id: String
  let englishName: String
  let chineseName: String
  let label: String
  let englishDetail: String
  let chineseDetail: String
  let launchOnlyOnce: Bool
  var loaded = false
  var pids: [Int32] = []
  var flags: [String] = []
  var disabled = false
  var restartRequired = false
  var present = true

  func name(_ language: AppLanguage) -> String {
    language == .simplifiedChinese ? chineseName : englishName
  }

  func detail(_ language: AppLanguage) -> String {
    language == .simplifiedChinese ? chineseDetail : englishDetail
  }

  func stateText(_ language: AppLanguage) -> String {
    if restartRequired { return text(language, "Stopped · Ready to re-register", "已停止 · 可重新注册") }
    if !present { return text(language, "Not installed", "未安装") }
    if disabled, !loaded { return text(language, "Disabled by policy", "已被策略禁用") }
    if loaded, pids.isEmpty { return text(language, "Loaded · Waiting for trigger", "已加载 · 等待触发") }
    if loaded { return text(language, "Running", "运行中") }
    if !pids.isEmpty { return text(language, "Inconsistent · Remaining process", "异常 · 有残留进程") }
    return text(language, "Stopped", "已停止")
  }

  var stateColor: Color {
    if restartRequired || (!loaded && !pids.isEmpty) { return .orange }
    if loaded { return .green }
    return .secondary
  }

  func pidText(_ language: AppLanguage) -> String {
    pids.isEmpty ? text(language, "None", "无") : pids.map(String.init).joined(separator: ", ")
  }

  static let definitions = [
    ComponentStatus(
      id: "connection", englishName: "Connection Service", chineseName: "连接主服务",
      label: "com.volcengine.corplink.service", englishDetail: "Local service for VPN, SWG, and Corplink connectivity",
      chineseDetail: "VPN、SWG 和飞连本地连接服务", launchOnlyOnce: false),
    ComponentStatus(
      id: "protection", englishName: "System Protection", chineseName: "系统防护",
      label: "com.volcengine.corplink.systemextension", englishDetail: "EDR, AV, EDLP, firewall, and device controls",
      chineseDetail: "EDR、AV、EDLP、防火墙、设备管控", launchOnlyOnce: false),
    ComponentStatus(
      id: "network-monitor", englishName: "Network Monitor", chineseName: "网络监控",
      label: "com.corplink.networkmonitor", englishDetail: "LaunchOnlyOnce; re-registers with the original plist when started again",
      chineseDetail: "LaunchOnlyOnce；再次启动会使用原始 plist 重新注册", launchOnlyOnce: true),
    ComponentStatus(
      id: "data-forwarder", englishName: "Policy Data Forwarder", chineseName: "策略数据转发",
      label: "com.corplink.data_forwarder", englishDetail: "On-demand policy forwarding task scheduled every 300 seconds",
      chineseDetail: "每 300 秒按需运行的策略转发任务", launchOnlyOnce: false),
    ComponentStatus(
      id: "mdm", englishName: "MDM Policy", chineseName: "MDM 策略",
      label: "com.corplink.mdm.policy", englishDetail: "Organization device-management policy; honors the system disabled state",
      chineseDetail: "组织设备管理策略；尊重系统中的禁用状态", launchOnlyOnce: false),
    ComponentStatus(
      id: "network-agent", englishName: "Network Extension Agent", chineseName: "网络扩展代理",
      label: "com.volcengine.corplink.agent", englishDetail: "CorplinkNe network agent for the current user",
      chineseDetail: "当前用户的 CorplinkNe 网络代理", launchOnlyOnce: false),
    ComponentStatus(
      id: "app-blocker", englishName: "Application Control", chineseName: "应用管控",
      label: "com.corplink.appblocker", englishDetail: "Application access control for the current user",
      chineseDetail: "当前用户的应用访问管控", launchOnlyOnce: false),
    ComponentStatus(
      id: "client", englishName: "Client Login Item", chineseName: "客户端登录项",
      label: "CorpLink", englishDetail: "Login task for the Corplink client interface",
      chineseDetail: "飞连客户端界面登录任务", launchOnlyOnce: false),
  ]
}

private struct CommandResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

@MainActor
private final class ServiceController: ObservableObject {
  @Published var language: AppLanguage {
    didSet {
      UserDefaults.standard.set(language.rawValue, forKey: AppConstants.languageKey)
      if oldValue != language { refresh() }
    }
  }
  @Published var state: ServiceState = .loading
  @Published var flags: [String] = []
  @Published var isBusy = false
  @Published var message: String?
  @Published var isError = false
  @Published var vpnStatus = "unknown"
  @Published var swgStatus = "unknown"
  @Published var components = ComponentStatus.definitions
  @Published var activeSystemExtensions: [String] = []
  @Published var suiteClean = false
  @Published var suiteLoaded = 0
  @Published var suiteTotal = ComponentStatus.definitions.count
  @Published var suiteProcesses = 0
  @Published var restorePending: [String] = []
  @Published var auxiliaryComponents: [String] = []
  @Published var auxiliaryPIDs: [Int32] = []
  @Published var hasStatus = false

  private var isFetchingStatus = false
  private var statusRequestID = 0

  init() {
    language =
      AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: AppConstants.languageKey) ?? "")
      ?? .english
  }

  var suiteTitle: String {
    if !hasStatus { return text(language, "Checking the complete Corplink suite…", "正在检查整套飞连…") }
    if suiteClean { return text(language, "Corplink is stopped", "飞连已停止") }
    if suiteLoaded == 0 { return text(language, "Corplink state is inconsistent", "飞连状态异常") }
    return text(language, "Corplink is running", "飞连运行中")
  }

  var suiteDetail: String {
    if !hasStatus { return "" }
    return text(
      language,
      "\(suiteLoaded) / \(suiteTotal) services loaded · \(suiteProcesses) processes",
      "已加载 \(suiteLoaded) / \(suiteTotal) 个服务 · \(suiteProcesses) 个进程")
  }

  var suiteSymbol: String {
    if !hasStatus { return "arrow.clockwise" }
    if suiteClean { return "shield.slash" }
    if suiteLoaded > 0 { return "checkmark.shield.fill" }
    return "exclamationmark.shield.fill"
  }

  var suiteColor: Color {
    if !hasStatus { return .secondary }
    if suiteClean { return .secondary }
    if suiteLoaded > 0 { return .green }
    return .orange
  }

  var isWorking: Bool { isBusy }

  var canStartSuite: Bool {
    components.contains { !$0.loaded && $0.present && !$0.disabled }
  }

  private var helperURL: URL? {
    Bundle.main.url(forResource: "corplink-root-helper", withExtension: nil)
  }

  func refresh() {
    guard !isBusy, !isFetchingStatus, let helperURL else {
      if helperURL == nil {
        showMessage(
          text(language, "The control helper is missing from the app. Rebuild the app.", "App 内缺少控制 helper，请重新构建。"),
          error: true)
      }
      return
    }
    isFetchingStatus = true
    statusRequestID += 1
    let requestID = statusRequestID
    Task {
      let result = await Self.run(
        helperURL, arguments: ["status"],
        environment: ["CORPLINK_CONTROL_LANG": language.helperCode])
      guard requestID == statusRequestID else { return }
      if !isBusy {
        applyStatus(result)
      }
      isFetchingStatus = false
    }
  }

  func perform(_ action: String) {
    guard !isBusy, let helperURL else { return }
    statusRequestID += 1
    isFetchingStatus = false
    isBusy = true
    message = nil
    Task {
      let shouldDisconnect =
        action == "stop" || action == "stop-suite"
        || action == "stop-component:connection"
      let currentLanguage = language
      let disconnectSummary =
        shouldDisconnect ? await Self.disconnectNetworkSessions(language: currentLanguage) : nil
      let result = await Self.runWithAdministratorPrivileges(
        helperURL, action: action, language: currentLanguage)
      if result.status == 0 {
        let outputText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [
          disconnectSummary,
          outputText.isEmpty
            ? text(currentLanguage, "Operation completed successfully", "操作成功") : outputText,
        ].compactMap { $0 }
        showMessage(parts.joined(separator: "\n"), error: false)
      } else {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = detail.contains("User canceled") || detail.contains("(-128)")
        showMessage(
          cancelled
            ? text(currentLanguage, "Administrator authorization was cancelled", "已取消管理员授权")
            : (detail.isEmpty ? text(currentLanguage, "Operation failed", "操作失败") : detail),
          error: true)
      }
      let statusResult = await Self.run(
        helperURL, arguments: ["status"],
        environment: ["CORPLINK_CONTROL_LANG": currentLanguage.helperCode])
      applyStatus(statusResult)
      isBusy = false
    }
  }

  private func applyStatus(_ result: CommandResult) {
    let values = Dictionary(
      uniqueKeysWithValues: result.stdout.split(separator: "\n").compactMap { row in
        let pair = row.split(separator: "=", maxSplits: 1).map(String.init)
        return pair.count == 2 ? (pair[0], pair[1]) : nil
      })
    components = ComponentStatus.definitions.map { definition in
      var component = definition
      let fields = (values["job.\(definition.id)"] ?? "").split(
        separator: "|", maxSplits: 5, omittingEmptySubsequences: false
      ).map(String.init)
      guard fields.count == 6 else { return component }
      component.loaded = fields[0] == "1"
      component.pids = fields[1].split(separator: ":").compactMap { Int32($0) }
      component.flags = fields[2].split(separator: ":").map(String.init).filter { $0 != "-" }
      component.disabled = fields[3] == "1"
      component.restartRequired = fields[4] == "1"
      component.present = fields[5] == "1"
      return component
    }
    let connection = components.first { $0.id == "connection" } ?? ComponentStatus.definitions[0]
    let loaded = connection.loaded
    let pids = connection.pids
    flags = connection.flags
    vpnStatus = values["vpn"] ?? "unknown"
    swgStatus = values["swg"] ?? "unknown"
    suiteClean = values["suite_clean"] == "true"
    suiteLoaded = Int(values["suite_loaded"] ?? "") ?? 0
    suiteTotal = Int(values["suite_total"] ?? "") ?? ComponentStatus.definitions.count
    suiteProcesses = Int(values["suite_processes"] ?? "") ?? 0
    restorePending = (values["restore_pending"] ?? "").split(separator: ",").map(String.init)
    auxiliaryComponents = (values["auxiliary_components"] ?? "").split(separator: ",").map(
      String.init)
    auxiliaryPIDs = (values["auxiliary_pids"] ?? "").split(separator: ",").compactMap { Int32($0) }
    activeSystemExtensions = (values["system_extensions"] ?? "").split(separator: ",").map(
      String.init)
    hasStatus = true

    if loaded, !pids.isEmpty {
      state = .running(pids)
    } else if !loaded, pids.isEmpty {
      state = .stopped
    } else {
      state = .inconsistent(loaded: loaded, pids: pids)
    }
  }

  private func showMessage(_ text: String, error: Bool) {
    message = text
    isError = error
  }

  func connectionStatusText(_ value: String) -> String {
    switch value.lowercased() {
    case "connected", "connecting", "reasserting": return text(language, "Connected", "已连接")
    case "disconnected", "disconnecting", "notsetup": return text(language, "Disconnected", "未连接")
    case "unavailable": return text(language, "Unavailable while the main service is stopped", "主服务未运行，无法查询")
    default: return text(language, "Unknown", "未知")
    }
  }

  nonisolated private static func disconnectNetworkSessions(language: AppLanguage) async -> String {
    let cliURL = URL(fileURLWithPath: AppConstants.cliPath)
    guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
      return text(
        language, "corplink-cli was not found; skipped the active VPN/SWG disconnect step.",
        "未找到 corplink-cli，跳过 VPN/SWG 主动断开步骤。")
    }

    let vpnResult = await run(cliURL, arguments: ["vpn", "disconnect"])
    let swgResult = await run(cliURL, arguments: ["swg", "disconnect"])
    let vpnText =
      vpnResult.status == 0
      ? text(language, "VPN disconnected", "VPN 已主动断开")
      : text(language, "VPN had no active connection or the main service did not respond", "VPN 无活动连接或主服务未响应")
    let swgText =
      swgResult.status == 0
      ? text(language, "SWG disconnected", "SWG 已主动断开")
      : text(language, "SWG had no active connection or the main service did not respond", "SWG 无活动连接或主服务未响应")
    return "\(vpnText); \(swgText)."
  }

  nonisolated private static func run(
    _ executable: URL, arguments: [String], environment: [String: String] = [:]
  ) async -> CommandResult
  {
    await Task.detached {
      let process = Process()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.executableURL = executable
      process.arguments = arguments
      if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
      }
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
      }
      return CommandResult(
        status: process.terminationStatus,
        stdout: String(
          decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(
          decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      )
    }.value
  }

  nonisolated private static func runWithAdministratorPrivileges(
    _ helper: URL, action: String, language: AppLanguage
  )
    async -> CommandResult
  {
    let command =
      "CORPLINK_CONTROL_LANG=\(shellQuote(language.helperCode)) \(shellQuote(helper.path)) \(shellQuote(action))"
    let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
    return await run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script])
  }

  nonisolated private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  nonisolated private static func appleScriptEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
  case control
  case components
  case information
  case settings
  case about

  var id: Self { self }

  func title(_ language: AppLanguage) -> String {
    switch self {
    case .control: return text(language, "Control", "控制")
    case .components: return text(language, "Components", "组件")
    case .information: return text(language, "Information", "信息")
    case .settings: return text(language, "Settings", "设置")
    case .about: return text(language, "About", "关于")
    }
  }

  var symbol: String {
    switch self {
    case .control: return "switch.2"
    case .components: return "square.stack.3d.up"
    case .information: return "info.circle"
    case .settings: return "gearshape"
    case .about: return "app.badge"
    }
  }
}

@MainActor
private final class LaunchAtLoginController: ObservableObject {
  private enum Status: Equatable {
    case checking, enabled, requiresApproval, notRegistered, notFound, unknown
  }

  @Published var isEnabled = false
  @Published private var status: Status = .checking
  @Published var errorMessage: String?

  init() {
    refresh()
  }

  func refresh() {
    switch SMAppService.mainApp.status {
    case .enabled:
      isEnabled = true
      status = .enabled
    case .requiresApproval:
      isEnabled = false
      status = .requiresApproval
    case .notRegistered:
      isEnabled = false
      status = .notRegistered
    case .notFound:
      isEnabled = false
      status = .notFound
    @unknown default:
      isEnabled = false
      status = .unknown
    }
  }

  func statusText(_ language: AppLanguage) -> String {
    switch status {
    case .checking: return text(language, "Checking…", "正在检查…")
    case .enabled: return text(language, "Enabled", "已启用")
    case .requiresApproval:
      return text(language, "Waiting for approval in System Settings", "等待在系统设置中批准")
    case .notRegistered: return text(language, "Not enabled", "未启用")
    case .notFound: return text(language, "Login item not found by the system", "系统找不到登录项")
    case .unknown: return text(language, "Unknown", "未知状态")
    }
  }

  var requiresApproval: Bool { status == .requiresApproval }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    refresh()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    let defaults = UserDefaults.standard
    let keepRunning =
      defaults.object(forKey: AppConstants.keepRunningKey) == nil
      ? true : defaults.bool(forKey: AppConstants.keepRunningKey)
    return !keepRunning
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    if let mainWindow = sender.windows.first(where: { window in
      window.identifier?.rawValue == "main"
        || window.title == "Corplink Control" || window.title == "飞连控制"
    }) {
      mainWindow.makeKeyAndOrderFront(nil)
    }
    return true
  }
}

private struct MainWindowView: View {
  @ObservedObject var controller: ServiceController
  @Environment(\.scenePhase) private var scenePhase
  @State private var selection: SidebarItem? = .control

  private var mainWindowIsVisible: Bool {
    NSApp.isActive
      && NSApp.windows.contains { window in
        window.isVisible && !window.isMiniaturized
          && (window.identifier?.rawValue == "main"
            || window.title == "Corplink Control" || window.title == "飞连控制")
      }
  }

  var body: some View {
    NavigationSplitView {
      List(SidebarItem.allCases, selection: $selection) { item in
        Label(item.title(controller.language), systemImage: item.symbol)
          .tag(item)
      }
      .navigationTitle(text(controller.language, "Corplink Control", "飞连控制"))
      .navigationSplitViewColumnWidth(min: 150, ideal: 170)
    } detail: {
      Group {
        switch selection ?? .control {
        case .control:
          ControlView(controller: controller)
        case .components:
          ComponentsView(controller: controller)
        case .information:
          InformationView(controller: controller)
        case .settings:
          SettingsView(controller: controller)
        case .about:
          AboutView(controller: controller)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 680, minHeight: 460)
    .onAppear { controller.refresh() }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      do {
        try await Task.sleep(nanoseconds: 150_000_000)
      } catch {
        return
      }
      if mainWindowIsVisible {
        controller.refresh()
      }
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
          return
        }
        if mainWindowIsVisible {
          controller.refresh()
        }
      }
    }
  }
}

private struct PageHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.largeTitle.bold())
      Text(subtitle).foregroundStyle(.secondary)
    }
  }
}

private struct StatusCard: View {
  @ObservedObject var controller: ServiceController

  var body: some View {
    HStack(spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 14)
          .fill(controller.suiteColor.opacity(0.13))
        Image(systemName: controller.suiteSymbol)
          .font(.system(size: 32, weight: .semibold))
          .foregroundStyle(controller.suiteColor)
      }
      .frame(width: 64, height: 64)

      VStack(alignment: .leading, spacing: 5) {
        Text(controller.suiteTitle).font(.title3.bold())
        Text(controller.suiteDetail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if controller.isBusy { ProgressView() }
    }
    .padding(18)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct ControlView: View {
  @ObservedObject var controller: ServiceController
  @State private var confirmStopSuite = false

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      PageHeader(
        title: text(controller.language, "Control", "控制"),
        subtitle: text(controller.language, "Start or stop the complete Corplink suite", "一键开始或停止飞连"))
      StatusCard(controller: controller)

      HStack(spacing: 12) {
        Button {
          controller.perform("start-suite")
        } label: {
          Label(text(controller.language, "Start", "开始"), systemImage: "play.fill")
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(controller.isWorking || !controller.canStartSuite)

        Button(role: .destructive) {
          confirmStopSuite = true
        } label: {
          Label(text(controller.language, "Stop", "停止"), systemImage: "stop.fill")
            .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(controller.isWorking || controller.suiteClean)

        Button {
          controller.refresh()
        } label: {
          Label(text(controller.language, "Refresh", "刷新"), systemImage: "arrow.clockwise")
            .frame(minWidth: 80)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(controller.isWorking)
      }

      if let message = controller.message {
        Label(
          message, systemImage: controller.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
        )
        .font(.callout)
        .foregroundStyle(controller.isError ? .red : .secondary)
        .textSelection(.enabled)
      }

      Spacer()
    }
    .padding(32)
    .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
    .alert(
      text(controller.language, "Stop the complete Corplink suite?", "确定停止整套飞连？"),
      isPresented: $confirmStopSuite
    ) {
      Button(text(controller.language, "Cancel", "取消"), role: .cancel) {}
      Button(text(controller.language, "Stop", "停止"), role: .destructive) {
        controller.perform("stop-suite")
      }
    } message: {
      Text(
        text(
          controller.language,
          "All known Corplink jobs and related processes will be stopped. Starting again will launch every installed component that is not disabled by policy.",
          "将停止全部已知飞连任务和相关进程。再次开始时会启动所有已安装且未被组织策略禁用的组件。"))
    }
  }
}

private struct ComponentsView: View {
  @ObservedObject var controller: ServiceController
  @State private var componentToStop: ComponentStatus?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(
          title: text(controller.language, "Components", "组件"),
          subtitle: text(
            controller.language, "Inspect jobs, processes, file flags, and recovery conditions",
            "逐项查看任务、进程、保护属性和恢复条件"))

        ForEach(controller.components) { component in
          HStack(alignment: .center, spacing: 14) {
            Circle()
              .fill(component.stateColor)
              .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 5) {
              HStack(spacing: 8) {
                Text(component.name(controller.language)).font(.headline)
                Text(component.stateText(controller.language))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(component.stateColor)
              }
              Text(component.label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Text(component.detail(controller.language)).font(.caption).foregroundStyle(.secondary)
              HStack(spacing: 14) {
                Text("PID: \(component.pidText(controller.language))")
                Text(
                  "\(text(controller.language, "Flags", "属性")): \(component.flags.isEmpty ? text(controller.language, "None", "无") : component.flags.joined(separator: ", "))")
              }
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            }

            Spacer()

            if component.loaded || !component.pids.isEmpty {
              Button(text(controller.language, "Stop", "停止"), role: .destructive) {
                componentToStop = component
              }
              .disabled(controller.isWorking)
            } else {
              Button(text(controller.language, "Start", "启动")) {
                controller.perform("start-component:\(component.id)")
              }
              .disabled(
                controller.isWorking || !component.present || component.disabled)
            }
          }
          .padding(14)
          .background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }

        HStack {
          Button {
            controller.refresh()
          } label: {
            Label(
              text(controller.language, "Refresh All Status", "刷新全部状态"),
              systemImage: "arrow.clockwise")
          }
          .disabled(controller.isWorking)
          Spacer()
          Text(
            text(
              controller.language, "Silently refreshes every 30 seconds while the main window is in front",
              "主窗口位于前台时，每 30 秒静默刷新"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .alert(
      text(
        controller.language,
        "Stop \(componentToStop?.name(controller.language) ?? "component")?",
        "停止\(componentToStop?.name(controller.language) ?? "组件")？"),
      isPresented: Binding(
        get: { componentToStop != nil },
        set: { if !$0 { componentToStop = nil } }
      )
    ) {
      Button(text(controller.language, "Cancel", "取消"), role: .cancel) { componentToStop = nil }
      Button(text(controller.language, "Stop", "停止"), role: .destructive) {
        if let componentToStop {
          controller.perform("stop-component:\(componentToStop.id)")
        }
        componentToStop = nil
      }
    } message: {
      if componentToStop?.launchOnlyOnce == true {
        Text(
          text(
            controller.language,
            "This job is marked LaunchOnlyOnce. Starting it again re-registers the original Corplink plist. Restarting the Mac remains the reliable fallback if verification fails.",
            "此任务标记为 LaunchOnlyOnce。再次启动时会使用飞连原始 plist 重新注册；若验证失败，重启 Mac 是可靠兜底。"))
      } else {
        Text(
          text(
            controller.language,
            "The job will be removed from its launchd domain and checked for remaining processes.",
            "将从对应 launchd domain 卸载任务，并验证没有相关进程残留。"))
      }
    }
  }
}

private struct InformationView: View {
  @ObservedObject var controller: ServiceController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          title: text(controller.language, "Information", "信息"),
          subtitle: text(controller.language, "Service, process, and configuration details", "服务、进程和配置文件详情"))

        GroupBox {
          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            InfoRow(
              label: text(controller.language, "Suite status", "整套状态"),
              value: controller.suiteClean
                ? text(controller.language, "Cleanly stopped", "已干净停止")
                : text(controller.language, "Components are running", "有组件运行"))
            InfoRow(
              label: text(controller.language, "Loaded jobs", "加载任务"),
              value: "\(controller.suiteLoaded) / \(controller.suiteTotal)")
            InfoRow(
              label: text(controller.language, "Related processes", "相关进程"),
              value: String(controller.suiteProcesses))
            Divider().gridCellColumns(2)
            InfoRow(label: text(controller.language, "Connection label", "连接标识"), value: AppConstants.serviceLabel)
            InfoRow(label: "system domain", value: controller.state.domainText(controller.language))
            InfoRow(label: text(controller.language, "Connection PID", "连接服务 PID"), value: controller.state.pidText(controller.language))
            InfoRow(label: "VPN", value: controller.connectionStatusText(controller.vpnStatus))
            InfoRow(label: "SWG", value: controller.connectionStatusText(controller.swgStatus))
            InfoRow(
              label: text(controller.language, "plist flags", "plist 属性"),
              value: controller.flags.isEmpty
                ? text(controller.language, "None", "无") : controller.flags.joined(separator: ", "))
            Divider().gridCellColumns(2)
            InfoRow(
              label: text(controller.language, "Pending recovery", "待恢复组件"),
              value: controller.restorePending.isEmpty
                ? text(controller.language, "None", "无") : controller.restorePending.joined(separator: ", "))
            InfoRow(
              label: text(controller.language, "Auxiliary processes", "辅助进程"),
              value: controller.auxiliaryComponents.isEmpty
                ? text(controller.language, "None", "无") : controller.auxiliaryComponents.joined(separator: ", "))
            InfoRow(
              label: text(controller.language, "Auxiliary PIDs", "辅助 PID"),
              value: controller.auxiliaryPIDs.isEmpty
                ? text(controller.language, "None", "无") : controller.auxiliaryPIDs.map(String.init).joined(separator: ", "))
            InfoRow(
              label: text(controller.language, "Active system extensions", "活跃系统扩展"),
              value: controller.activeSystemExtensions.isEmpty
                ? text(controller.language, "No related extension detected", "未检测到飞连扩展")
                : controller.activeSystemExtensions.joined(separator: ", "))
            Divider().gridCellColumns(2)
            InfoRow(label: text(controller.language, "Executable", "可执行文件"), value: AppConstants.executablePath)
            InfoRow(label: text(controller.language, "Service configuration", "服务配置"), value: AppConstants.plistPath)
          }
          .padding(10)
        }

        GroupBox(text(controller.language, "Suite control boundaries", "整套开关边界")) {
          Text(
            text(
              controller.language,
              "Stop removes and verifies each component. Start launches every installed component not disabled by policy, regardless of its previous state. Network Monitor is re-registered with the original Corplink plist; restart the Mac if verification fails. Active system extensions are not uninstalled and prevent a clean-stop result while active.",
              "停止整套会逐项卸载并验证；开始整套会启动所有已安装且未被组织策略禁用的组件，不参考停止前状态。网络监控使用飞连原始 plist 重新注册，失败时需重启 Mac。活跃 System Extension 不会被卸载，若仍存在就不会报告为干净停止。")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(8)
        }

        Button {
          controller.refresh()
        } label: {
          Label(text(controller.language, "Refresh Information", "刷新信息"), systemImage: "arrow.clockwise")
        }
        .disabled(controller.isWorking)
      }
      .padding(28)
      .frame(maxWidth: 760, alignment: .leading)
    }
  }
}

private struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 105, alignment: .leading)
      Text(value)
        .fontDesign(.monospaced)
        .textSelection(.enabled)
    }
  }
}

private struct SettingsView: View {
  @ObservedObject var controller: ServiceController
  @AppStorage("showMenuBarItem") private var showMenuBarItem = true
  @AppStorage(AppConstants.keepRunningKey) private var keepRunningAfterWindowClose = true
  @StateObject private var loginController = LaunchAtLoginController()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          title: text(controller.language, "Settings", "设置"),
          subtitle: text(controller.language, "Choose how the app starts and stays available", "调整 App 的启动方式和入口"))

        GroupBox(text(controller.language, "Language", "语言")) {
          Picker(
            text(controller.language, "App language", "App 语言"),
            selection: Binding(
              get: { controller.language },
              set: { controller.language = $0 }
            )
          ) {
            ForEach(AppLanguage.allCases) { language in
              Text(language.displayName).tag(language)
            }
          }
          .pickerStyle(.segmented)
          .padding(8)
        }

        GroupBox(text(controller.language, "Window and menu bar", "窗口与菜单栏")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle(
              text(controller.language, "Show menu bar icon", "显示菜单栏图标"),
              isOn: $showMenuBarItem)
            Text(
              text(
                controller.language,
                "Turn this off when the menu bar is crowded. The main window remains available from the Dock, Spotlight, or Applications.",
                "菜单栏拥挤时可以关闭。主窗口仍可通过 Dock、Spotlight 或“应用程序”打开。"))
              .font(.caption)
              .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Toggle(
              text(
                controller.language, "Keep running after closing the main window",
                "关闭主窗口后继续运行"),
              isOn: $keepRunningAfterWindowClose)
            Text(
              text(
                controller.language,
                "When enabled, closing the main window leaves the app available in the background and menu bar. When disabled, closing the last window quits the entire app.",
                "开启后，关闭主窗口仍会保留后台和菜单栏入口；关闭后，关掉最后一个窗口会退出整个 App。"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(8)
        }

        GroupBox(text(controller.language, "Login item", "登录项")) {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              text(controller.language, "Launch Corplink Control at login", "登录时启动控制 App"),
              isOn: Binding(
                get: { loginController.isEnabled },
                set: { loginController.setEnabled($0) }
              )
            )
            Text(
              "\(text(controller.language, "Current status", "当前状态")): \(loginController.statusText(controller.language))")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(
              text(
                controller.language,
                "This controls whether Corplink Control opens at login. It does not automatically change the Corplink service state.",
                "这里只控制“飞连控制”App 是否随登录启动，不会自动改变飞连连接服务的运行状态。"))
              .font(.caption)
              .foregroundStyle(.secondary)

            if loginController.requiresApproval {
              Button(text(controller.language, "Open Login Items Settings", "打开登录项设置")) {
                loginController.openSystemSettings()
              }
            }
            if let error = loginController.errorMessage {
              Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
          }
          .padding(8)
        }
      }
      .padding(28)
      .frame(maxWidth: 720, alignment: .leading)
    }
  }
}

private struct AboutView: View {
  @ObservedObject var controller: ServiceController

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? text(controller.language, "Unknown", "未知")
  }

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "checkmark.shield.fill")
        .font(.system(size: 64))
        .foregroundStyle(.blue)
      Text(text(controller.language, "Corplink Control", "飞连控制")).font(.largeTitle.bold())
      Text("\(text(controller.language, "Version", "版本")) \(version)").foregroundStyle(.secondary)
      Text(
        text(
          controller.language,
          "Inspect, start, and cleanly stop Corplink runtime components on macOS.",
          "用于逐项查看、启动和干净停止飞连 macOS 运行组件。"))
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Link(destination: AppConstants.repositoryURL) {
        Label(
          text(controller.language, "View on GitHub", "在 GitHub 上查看"),
          systemImage: "arrow.up.right.square")
      }
      Divider().frame(width: 320)
      Text(
        text(
          controller.language,
          "This tool does not delete Corplink files or override organization policy. Start launches every available component; restart the Mac if Network Monitor cannot be re-registered.",
          "本工具不会删除飞连文件或篡改组织禁用策略。开始会启动全部可用组件；网络监控重新注册失败时需要重启 Mac。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct MenuBarView: View {
  @ObservedObject var controller: ServiceController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: controller.suiteSymbol)
          .font(.title2)
          .foregroundStyle(controller.suiteColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(controller.suiteTitle).font(.headline)
          Text(controller.suiteDetail).font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack {
        Button(text(controller.language, "Start Suite", "启动整套")) {
          controller.perform("start-suite")
        }
          .disabled(controller.isWorking || !controller.canStartSuite)
        Button(text(controller.language, "Refresh", "刷新")) { controller.refresh() }
          .disabled(controller.isWorking)
      }

      Divider()

      HStack {
        Button(text(controller.language, "Open Main Window", "打开主窗口")) {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "main")
        }
        Spacer()
        Button(text(controller.language, "Quit", "退出")) { NSApp.terminate(nil) }
      }
    }
    .padding(16)
    .frame(width: 310)
    .onAppear { controller.refresh() }
  }
}

private enum SnowMikuMenuBarState {
  case checking, running, stopped, inconsistent
}

private enum SnowMikuMenuBarIcon {
  static func image(state: SnowMikuMenuBarState) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()

      let snowflake = NSBezierPath()
      snowflake.move(to: NSPoint(x: 8.3, y: 2.0))
      snowflake.line(to: NSPoint(x: 8.3, y: 14.5))
      snowflake.move(to: NSPoint(x: 3.0, y: 5.2))
      snowflake.line(to: NSPoint(x: 13.6, y: 11.3))
      snowflake.move(to: NSPoint(x: 13.6, y: 5.2))
      snowflake.line(to: NSPoint(x: 3.0, y: 11.3))

      snowflake.move(to: NSPoint(x: 8.3, y: 4.4))
      snowflake.line(to: NSPoint(x: 6.8, y: 3.5))
      snowflake.move(to: NSPoint(x: 8.3, y: 4.4))
      snowflake.line(to: NSPoint(x: 9.8, y: 3.5))
      snowflake.move(to: NSPoint(x: 8.3, y: 12.1))
      snowflake.line(to: NSPoint(x: 6.8, y: 13.0))
      snowflake.move(to: NSPoint(x: 8.3, y: 12.1))
      snowflake.line(to: NSPoint(x: 9.8, y: 13.0))

      snowflake.move(to: NSPoint(x: 5.0, y: 6.4))
      snowflake.line(to: NSPoint(x: 4.0, y: 4.7))
      snowflake.move(to: NSPoint(x: 5.0, y: 6.4))
      snowflake.line(to: NSPoint(x: 3.9, y: 7.0))
      snowflake.move(to: NSPoint(x: 11.6, y: 10.1))
      snowflake.line(to: NSPoint(x: 12.6, y: 9.5))
      snowflake.move(to: NSPoint(x: 11.6, y: 10.1))
      snowflake.line(to: NSPoint(x: 12.6, y: 11.9))

      snowflake.move(to: NSPoint(x: 11.6, y: 6.4))
      snowflake.line(to: NSPoint(x: 12.6, y: 4.7))
      snowflake.move(to: NSPoint(x: 11.6, y: 6.4))
      snowflake.line(to: NSPoint(x: 12.6, y: 7.0))
      snowflake.move(to: NSPoint(x: 5.0, y: 10.1))
      snowflake.line(to: NSPoint(x: 4.0, y: 9.5))
      snowflake.move(to: NSPoint(x: 5.0, y: 10.1))
      snowflake.line(to: NSPoint(x: 4.0, y: 11.9))
      snowflake.lineWidth = 1.35
      snowflake.lineCapStyle = .round
      snowflake.lineJoinStyle = .round
      snowflake.stroke()

      let statusDot = NSBezierPath(ovalIn: NSRect(x: 14.0, y: 13.6, width: 2.6, height: 2.6))
      statusDot.lineWidth = 1.05
      switch state {
      case .running:
        statusDot.fill()
      case .stopped:
        statusDot.stroke()
      case .checking:
        statusDot.setLineDash([1.4, 1.0], count: 2, phase: 0)
        statusDot.stroke()
      case .inconsistent:
        statusDot.stroke()
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 14.5, y: 14.1))
        mark.line(to: NSPoint(x: 16.1, y: 15.7))
        mark.lineWidth = 0.9
        mark.lineCapStyle = .round
        mark.stroke()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}

@main
private struct CorplinkControlApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var controller = ServiceController()
  @AppStorage("showMenuBarItem") private var showMenuBarItem = true

  private var snowMikuMenuBarState: SnowMikuMenuBarState {
    if !controller.hasStatus { return .checking }
    if controller.suiteClean { return .stopped }
    if controller.suiteLoaded > 0 { return .running }
    return .inconsistent
  }

  var body: some Scene {
    Window("Corplink Control", id: "main") {
      MainWindowView(controller: controller)
    }
    .defaultSize(width: 760, height: 520)

    MenuBarExtra(isInserted: $showMenuBarItem) {
      MenuBarView(controller: controller)
    } label: {
      Image(nsImage: SnowMikuMenuBarIcon.image(state: snowMikuMenuBarState))
        .accessibilityLabel("Corplink Control")
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(controller: controller)
        .frame(width: 560, height: 360)
    }
  }
}
