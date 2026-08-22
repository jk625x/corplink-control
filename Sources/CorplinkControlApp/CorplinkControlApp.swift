import AppKit
import Combine
import ServiceManagement
import SwiftUI

private enum AppConstants {
  static let serviceLabel = "com.volcengine.corplink.service"
  static let plistPath = "/Library/LaunchDaemons/com.volcengine.corplink.service.plist"
  static let executablePath = "/usr/local/corplink/corplink-service"
  static let cliPath = "/usr/local/corplink/corplink-cli"
  static let repositoryURL = URL(string: "https://github.com/jk625x/corplink-control")!
}

private enum ServiceState: Equatable {
  case loading
  case running([Int32])
  case stopped
  case inconsistent(loaded: Bool, pids: [Int32])

  var title: String {
    switch self {
    case .loading: return "正在检查…"
    case .running: return "飞连连接服务正在运行"
    case .stopped: return "飞连连接服务已停止"
    case .inconsistent: return "连接服务状态异常"
    }
  }

  var detail: String {
    switch self {
    case .loading: return ""
    case .running(let pids): return "PID \(pids.map(String.init).joined(separator: ", "))"
    case .stopped: return "未加载，且没有残留进程"
    case .inconsistent(let loaded, let pids):
      let processText =
        pids.isEmpty ? "无进程" : "PID \(pids.map(String.init).joined(separator: ", "))"
      return "system domain \(loaded ? "已加载" : "未加载") · \(processText)"
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

  var domainText: String {
    switch self {
    case .loading: return "检查中"
    case .running: return "已加载"
    case .stopped: return "未加载"
    case .inconsistent(let loaded, _): return loaded ? "已加载" : "未加载"
    }
  }

  var pidText: String {
    switch self {
    case .running(let pids), .inconsistent(_, let pids):
      return pids.isEmpty ? "无" : pids.map(String.init).joined(separator: ", ")
    case .loading: return "检查中"
    case .stopped: return "无"
    }
  }
}

private struct ComponentStatus: Identifiable, Equatable {
  let id: String
  let name: String
  let label: String
  let detail: String
  let launchOnlyOnce: Bool
  var loaded = false
  var pids: [Int32] = []
  var flags: [String] = []
  var disabled = false
  var restartRequired = false
  var present = true

  var stateText: String {
    if restartRequired { return "已停止 · 需要重启恢复" }
    if !present { return "未安装" }
    if disabled, !loaded { return "已被策略禁用" }
    if loaded, pids.isEmpty { return "已加载 · 等待触发" }
    if loaded { return "运行中" }
    if !pids.isEmpty { return "异常 · 有残留进程" }
    return "已停止"
  }

  var stateColor: Color {
    if restartRequired || (!loaded && !pids.isEmpty) { return .orange }
    if loaded { return .green }
    return .secondary
  }

  var pidText: String {
    pids.isEmpty ? "无" : pids.map(String.init).joined(separator: ", ")
  }

  static let definitions = [
    ComponentStatus(
      id: "connection", name: "连接主服务", label: "com.volcengine.corplink.service",
      detail: "VPN、SWG 和飞连本地连接服务", launchOnlyOnce: false),
    ComponentStatus(
      id: "protection", name: "系统防护", label: "com.volcengine.corplink.systemextension",
      detail: "EDR、AV、EDLP、防火墙、设备管控", launchOnlyOnce: false),
    ComponentStatus(
      id: "network-monitor", name: "网络监控", label: "com.corplink.networkmonitor",
      detail: "LaunchOnlyOnce；停止后必须重启 Mac 才能可靠恢复", launchOnlyOnce: true),
    ComponentStatus(
      id: "data-forwarder", name: "策略数据转发", label: "com.corplink.data_forwarder",
      detail: "每 300 秒按需运行的策略转发任务", launchOnlyOnce: false),
    ComponentStatus(
      id: "mdm", name: "MDM 策略", label: "com.corplink.mdm.policy",
      detail: "组织设备管理策略；尊重系统中的禁用状态", launchOnlyOnce: false),
    ComponentStatus(
      id: "network-agent", name: "网络扩展代理", label: "com.volcengine.corplink.agent",
      detail: "当前用户的 CorplinkNe 网络代理", launchOnlyOnce: false),
    ComponentStatus(
      id: "app-blocker", name: "应用管控", label: "com.corplink.appblocker",
      detail: "当前用户的应用访问管控", launchOnlyOnce: false),
    ComponentStatus(
      id: "client", name: "客户端登录项", label: "CorpLink",
      detail: "飞连客户端界面登录任务", launchOnlyOnce: false),
  ]
}

private struct CommandResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

@MainActor
private final class ServiceController: ObservableObject {
  @Published var state: ServiceState = .loading
  @Published var flags: [String] = []
  @Published var isBusy = false
  @Published var message: String?
  @Published var isError = false
  @Published var vpnStatus = "检查中"
  @Published var swgStatus = "检查中"
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

  var suiteTitle: String {
    if !hasStatus { return "正在检查整套飞连…" }
    if suiteClean { return "飞连已停止" }
    if suiteLoaded == 0 { return "飞连状态异常" }
    return "飞连运行中"
  }

  var suiteDetail: String {
    if !hasStatus { return "" }
    return "已加载 \(suiteLoaded) / \(suiteTotal) 个服务 · \(suiteProcesses) 个进程"
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

  var canRestoreWithoutRestart: Bool {
    restorePending.contains { $0 != "network-monitor" }
  }

  private var helperURL: URL? {
    Bundle.main.url(forResource: "corplink-root-helper", withExtension: nil)
  }

  func refresh() {
    guard !isBusy, !isFetchingStatus, let helperURL else {
      if helperURL == nil {
        showMessage("App 内缺少控制 helper，请重新构建。", error: true)
      }
      return
    }
    isFetchingStatus = true
    statusRequestID += 1
    let requestID = statusRequestID
    Task {
      let result = await Self.run(helperURL, arguments: ["status"])
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
      let disconnectSummary = shouldDisconnect ? await Self.disconnectNetworkSessions() : nil
      let result = await Self.runWithAdministratorPrivileges(helperURL, action: action)
      if result.status == 0 {
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [disconnectSummary, text.isEmpty ? "操作成功" : text].compactMap { $0 }
        showMessage(parts.joined(separator: "\n"), error: false)
      } else {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = detail.contains("User canceled") || detail.contains("(-128)")
        showMessage(cancelled ? "已取消管理员授权" : (detail.isEmpty ? "操作失败" : detail), error: true)
      }
      let statusResult = await Self.run(helperURL, arguments: ["status"])
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
    vpnStatus = Self.connectionStatusText(values["vpn"] ?? "unknown")
    swgStatus = Self.connectionStatusText(values["swg"] ?? "unknown")
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

  nonisolated private static func connectionStatusText(_ value: String) -> String {
    switch value.lowercased() {
    case "connected", "connecting", "reasserting": return "已连接"
    case "disconnected", "disconnecting", "notsetup": return "未连接"
    case "unavailable": return "主服务未运行，无法查询"
    default: return "未知"
    }
  }

  nonisolated private static func disconnectNetworkSessions() async -> String {
    let cliURL = URL(fileURLWithPath: AppConstants.cliPath)
    guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
      return "未找到 corplink-cli，跳过 VPN/SWG 主动断开步骤。"
    }

    let vpnResult = await run(cliURL, arguments: ["vpn", "disconnect"])
    let swgResult = await run(cliURL, arguments: ["swg", "disconnect"])
    let vpnText = vpnResult.status == 0 ? "VPN 已主动断开" : "VPN 无活动连接或主服务未响应"
    let swgText = swgResult.status == 0 ? "SWG 已主动断开" : "SWG 无活动连接或主服务未响应"
    return "\(vpnText)；\(swgText)。"
  }

  nonisolated private static func run(_ executable: URL, arguments: [String]) async -> CommandResult
  {
    await Task.detached {
      let process = Process()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.executableURL = executable
      process.arguments = arguments
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

  nonisolated private static func runWithAdministratorPrivileges(_ helper: URL, action: String)
    async -> CommandResult
  {
    let command = "\(shellQuote(helper.path)) \(shellQuote(action))"
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
  case control = "控制"
  case components = "组件"
  case information = "信息"
  case settings = "设置"
  case about = "关于"

  var id: Self { self }

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
  @Published var isEnabled = false
  @Published var statusText = "正在检查…"
  @Published var errorMessage: String?

  init() {
    refresh()
  }

  func refresh() {
    switch SMAppService.mainApp.status {
    case .enabled:
      isEnabled = true
      statusText = "已启用"
    case .requiresApproval:
      isEnabled = false
      statusText = "等待在系统设置中批准"
    case .notRegistered:
      isEnabled = false
      statusText = "未启用"
    case .notFound:
      isEnabled = false
      statusText = "系统找不到登录项"
    @unknown default:
      isEnabled = false
      statusText = "未知状态"
    }
  }

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

private struct MainWindowView: View {
  @ObservedObject var controller: ServiceController
  @Environment(\.scenePhase) private var scenePhase
  @State private var selection: SidebarItem? = .control

  private var mainWindowIsVisible: Bool {
    NSApp.isActive
      && NSApp.windows.contains { window in
        window.isVisible && !window.isMiniaturized && window.title == "飞连控制"
      }
  }

  var body: some View {
    NavigationSplitView {
      List(SidebarItem.allCases, selection: $selection) { item in
        Label(item.rawValue, systemImage: item.symbol)
          .tag(item)
      }
      .navigationTitle("飞连控制")
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
          SettingsView()
        case .about:
          AboutView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 680, minHeight: 460)
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
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
      PageHeader(title: "控制", subtitle: "一键开始或停止飞连")
      StatusCard(controller: controller)

      HStack(spacing: 12) {
        Button {
          controller.perform("restore-suite")
        } label: {
          Label("开始", systemImage: "play.fill")
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(controller.isWorking || !controller.canRestoreWithoutRestart)

        Button(role: .destructive) {
          confirmStopSuite = true
        } label: {
          Label("停止", systemImage: "stop.fill")
            .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(controller.isWorking || controller.suiteClean)

        Button {
          controller.refresh()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
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
    .alert("确定停止整套飞连？", isPresented: $confirmStopSuite) {
      Button("取消", role: .cancel) {}
      Button("停止", role: .destructive) { controller.perform("stop-suite") }
    } message: {
      Text("将停止当前运行的连接、防护、网络代理、应用管控等组件。网络监控停止后需要重启 Mac 才能可靠恢复。")
    }
  }
}

private struct ComponentsView: View {
  @ObservedObject var controller: ServiceController
  @State private var componentToStop: ComponentStatus?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: "组件", subtitle: "逐项查看任务、进程、保护属性和恢复条件")

        ForEach(controller.components) { component in
          HStack(alignment: .center, spacing: 14) {
            Circle()
              .fill(component.stateColor)
              .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 5) {
              HStack(spacing: 8) {
                Text(component.name).font(.headline)
                Text(component.stateText)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(component.stateColor)
              }
              Text(component.label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Text(component.detail).font(.caption).foregroundStyle(.secondary)
              HStack(spacing: 14) {
                Text("PID：\(component.pidText)")
                Text(
                  "属性：\(component.flags.isEmpty ? "无" : component.flags.joined(separator: ", "))")
              }
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            }

            Spacer()

            if component.loaded || !component.pids.isEmpty {
              Button(component.launchOnlyOnce ? "停止（需重启）" : "停止", role: .destructive) {
                componentToStop = component
              }
              .disabled(controller.isWorking)
            } else {
              Button("启动") {
                controller.perform("start-component:\(component.id)")
              }
              .disabled(
                controller.isWorking || !component.present || component.disabled
                  || component.restartRequired)
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
            Label("刷新全部状态", systemImage: "arrow.clockwise")
          }
          .disabled(controller.isWorking)
          Spacer()
          Text("主窗口位于前台时，每 30 秒静默刷新")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .alert(
      "停止\(componentToStop?.name ?? "组件")？",
      isPresented: Binding(
        get: { componentToStop != nil },
        set: { if !$0 { componentToStop = nil } }
      )
    ) {
      Button("取消", role: .cancel) { componentToStop = nil }
      Button("停止", role: .destructive) {
        if let componentToStop {
          controller.perform("stop-component:\(componentToStop.id)")
        }
        componentToStop = nil
      }
    } message: {
      if componentToStop?.launchOnlyOnce == true {
        Text("此任务标记为 LaunchOnlyOnce，停止后必须重启 Mac 才能可靠恢复。")
      } else {
        Text("将从对应 launchd domain 卸载任务，并验证没有相关进程残留。")
      }
    }
  }
}

private struct InformationView: View {
  @ObservedObject var controller: ServiceController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "信息", subtitle: "服务、进程和配置文件详情")

        GroupBox {
          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            InfoRow(label: "整套状态", value: controller.suiteClean ? "已干净停止" : "有组件运行")
            InfoRow(label: "加载任务", value: "\(controller.suiteLoaded) / \(controller.suiteTotal)")
            InfoRow(label: "相关进程", value: String(controller.suiteProcesses))
            Divider().gridCellColumns(2)
            InfoRow(label: "连接标识", value: AppConstants.serviceLabel)
            InfoRow(label: "system domain", value: controller.state.domainText)
            InfoRow(label: "连接服务 PID", value: controller.state.pidText)
            InfoRow(label: "VPN", value: controller.vpnStatus)
            InfoRow(label: "SWG", value: controller.swgStatus)
            InfoRow(
              label: "plist 属性",
              value: controller.flags.isEmpty ? "无" : controller.flags.joined(separator: ", "))
            Divider().gridCellColumns(2)
            InfoRow(
              label: "待恢复组件",
              value: controller.restorePending.isEmpty
                ? "无" : controller.restorePending.joined(separator: ", "))
            InfoRow(
              label: "辅助进程",
              value: controller.auxiliaryComponents.isEmpty
                ? "无" : controller.auxiliaryComponents.joined(separator: "、"))
            InfoRow(
              label: "辅助 PID",
              value: controller.auxiliaryPIDs.isEmpty
                ? "无" : controller.auxiliaryPIDs.map(String.init).joined(separator: ", "))
            InfoRow(
              label: "活跃系统扩展",
              value: controller.activeSystemExtensions.isEmpty
                ? "未检测到飞连扩展" : controller.activeSystemExtensions.joined(separator: ", "))
            Divider().gridCellColumns(2)
            InfoRow(label: "可执行文件", value: AppConstants.executablePath)
            InfoRow(label: "服务配置", value: AppConstants.plistPath)
          }
          .padding(10)
        }

        GroupBox("停止与恢复边界") {
          Text(
            "停止整套会保存运行快照并逐项验证。网络监控使用 LaunchOnlyOnce，停止后必须重启 Mac 才能可靠恢复；被组织策略禁用的任务不会被强制启用。活跃 System Extension 不会被卸载，若仍存在就不会报告为干净停止。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(8)
        }

        Button {
          controller.refresh()
        } label: {
          Label("刷新信息", systemImage: "arrow.clockwise")
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
  @AppStorage("showMenuBarItem") private var showMenuBarItem = true
  @StateObject private var loginController = LaunchAtLoginController()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "设置", subtitle: "调整 App 的启动方式和入口")

        GroupBox("显示") {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("显示菜单栏图标", isOn: $showMenuBarItem)
            Text("菜单栏拥挤时可以关闭。主窗口仍可通过 Dock、Spotlight 或“应用程序”打开。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(8)
        }

        GroupBox("登录项") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              "登录时启动控制 App",
              isOn: Binding(
                get: { loginController.isEnabled },
                set: { loginController.setEnabled($0) }
              )
            )
            Text("当前状态：\(loginController.statusText)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("这里只控制“飞连控制”App 是否随登录启动，不会自动改变飞连连接服务的运行状态。")
              .font(.caption)
              .foregroundStyle(.secondary)

            if loginController.statusText.contains("等待") {
              Button("打开登录项设置") { loginController.openSystemSettings() }
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
  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
  }

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "checkmark.shield.fill")
        .font(.system(size: 64))
        .foregroundStyle(.blue)
      Text("飞连控制").font(.largeTitle.bold())
      Text("版本 \(version)").foregroundStyle(.secondary)
      Text("用于逐项查看、启动和干净停止飞连 macOS 运行组件。")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Link(destination: AppConstants.repositoryURL) {
        Label("在 GitHub 上查看", systemImage: "arrow.up.right.square")
      }
      Divider().frame(width: 320)
      Text("本工具不会删除飞连文件或篡改组织禁用策略。停止整套时会保存恢复快照；LaunchOnlyOnce 组件需要重启 Mac 恢复。")
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
        Button("恢复整套") { controller.perform("restore-suite") }
          .disabled(controller.isWorking || !controller.canRestoreWithoutRestart)
        Button("刷新") { controller.refresh() }
          .disabled(controller.isWorking)
      }

      Divider()

      HStack {
        Button("打开主窗口") {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "main")
        }
        Spacer()
        Button("退出") { NSApp.terminate(nil) }
      }
    }
    .padding(16)
    .frame(width: 310)
    .onAppear { controller.refresh() }
  }
}

@main
private struct CorplinkControlApp: App {
  @StateObject private var controller = ServiceController()
  @AppStorage("showMenuBarItem") private var showMenuBarItem = true

  var body: some Scene {
    Window("飞连控制", id: "main") {
      MainWindowView(controller: controller)
    }
    .defaultSize(width: 760, height: 520)

    MenuBarExtra("飞连控制", systemImage: controller.suiteSymbol, isInserted: $showMenuBarItem) {
      MenuBarView(controller: controller)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .frame(width: 560, height: 360)
    }
  }
}
