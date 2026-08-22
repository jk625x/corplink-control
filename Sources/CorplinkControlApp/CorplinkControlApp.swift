import AppKit
import Combine
import ServiceManagement
import SwiftUI

private enum AppConstants {
  static let serviceLabel = "com.volcengine.corplink.service"
  static let plistPath = "/Library/LaunchDaemons/com.volcengine.corplink.service.plist"
  static let executablePath = "/usr/local/corplink/corplink-service"
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
    case .running: return "飞连服务正在运行"
    case .stopped: return "飞连服务已停止"
    case .inconsistent: return "服务状态异常"
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

  private var helperURL: URL? {
    Bundle.main.url(forResource: "corplink-root-helper", withExtension: nil)
  }

  func refresh() {
    guard !isBusy, let helperURL else {
      if helperURL == nil {
        showMessage("App 内缺少控制 helper，请重新构建。", error: true)
      }
      return
    }
    Task {
      let result = await Self.run(helperURL, arguments: ["status"])
      applyStatus(result)
    }
  }

  func perform(_ action: String) {
    guard !isBusy, let helperURL else { return }
    isBusy = true
    message = nil
    Task {
      let result = await Self.runWithAdministratorPrivileges(helperURL, action: action)
      isBusy = false
      if result.status == 0 {
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        showMessage(text.isEmpty ? "操作成功" : text, error: false)
      } else {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = detail.contains("User canceled") || detail.contains("(-128)")
        showMessage(cancelled ? "已取消管理员授权" : (detail.isEmpty ? "操作失败" : detail), error: true)
      }
      refresh()
    }
  }

  private func applyStatus(_ result: CommandResult) {
    let values = Dictionary(
      uniqueKeysWithValues: result.stdout.split(separator: "\n").compactMap { row in
        let pair = row.split(separator: "=", maxSplits: 1).map(String.init)
        return pair.count == 2 ? (pair[0], pair[1]) : nil
      })
    let loaded = values["loaded"] == "true"
    let pids = (values["pids"] ?? "").split(separator: ",").compactMap { Int32($0) }
    flags = (values["flags"] ?? "").split(separator: ",").map(String.init)

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
  case information = "信息"
  case settings = "设置"
  case about = "关于"

  var id: Self { self }

  var symbol: String {
    switch self {
    case .control: return "switch.2"
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
  @State private var selection: SidebarItem? = .control
  private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
    .onAppear { controller.refresh() }
    .onReceive(refreshTimer) { _ in controller.refresh() }
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
          .fill(controller.state.color.opacity(0.13))
        Image(systemName: controller.state.symbol)
          .font(.system(size: 32, weight: .semibold))
          .foregroundStyle(controller.state.color)
      }
      .frame(width: 64, height: 64)

      VStack(alignment: .leading, spacing: 5) {
        Text(controller.state.title).font(.title3.bold())
        Text(controller.state.detail)
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

  private var serviceToggle: Binding<Bool> {
    Binding(
      get: { controller.state.isRunning },
      set: { controller.perform($0 ? "start" : "stop") }
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "控制", subtitle: "启动或停止飞连后台服务")
        StatusCard(controller: controller)

        GroupBox {
          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text("飞连服务").font(.headline)
              Text("切换时会弹出 macOS 管理员授权窗口")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("飞连服务", isOn: serviceToggle)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.large)
              .disabled(controller.isBusy || controller.state.isLoading)
          }
          .padding(8)
        }

        HStack(spacing: 12) {
          Button {
            controller.perform("start")
          } label: {
            Label("启动服务", systemImage: "play.fill")
              .frame(minWidth: 110)
          }
          .buttonStyle(.borderedProminent)
          .disabled(controller.isBusy || controller.state.isRunning)

          Button {
            controller.perform("stop")
          } label: {
            Label("停止服务", systemImage: "stop.fill")
              .frame(minWidth: 110)
          }
          .buttonStyle(.bordered)
          .disabled(controller.isBusy || controller.state.isStopped)

          Button {
            controller.refresh()
          } label: {
            Label("刷新", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .disabled(controller.isBusy)
        }

        if let message = controller.message {
          Label(
            message, systemImage: controller.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
          )
          .font(.callout)
          .foregroundStyle(controller.isError ? .red : .secondary)
          .textSelection(.enabled)
        }

        Text("服务配置包含 KeepAlive。停止操作会先移除 plist 的不可变属性，再从 system domain 卸载服务，避免进程被自动拉起。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(28)
      .frame(maxWidth: 720, alignment: .leading)
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
            InfoRow(label: "服务标识", value: AppConstants.serviceLabel)
            Divider().gridCellColumns(2)
            InfoRow(label: "system domain", value: controller.state.domainText)
            InfoRow(label: "进程 PID", value: controller.state.pidText)
            InfoRow(
              label: "plist 属性",
              value: controller.flags.isEmpty ? "无" : controller.flags.joined(separator: ", "))
            Divider().gridCellColumns(2)
            InfoRow(label: "可执行文件", value: AppConstants.executablePath)
            InfoRow(label: "服务配置", value: AppConstants.plistPath)
          }
          .padding(10)
        }

        Button {
          controller.refresh()
        } label: {
          Label("刷新信息", systemImage: "arrow.clockwise")
        }
        .disabled(controller.isBusy)
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
            Text("这里只控制“飞连控制”App 是否随登录启动，不会自动改变飞连服务的运行状态。")
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
      Text("用于查看、启动和停止飞连 macOS 后台服务。")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Link(destination: AppConstants.repositoryURL) {
        Label("在 GitHub 上查看", systemImage: "arrow.up.right.square")
      }
      Divider().frame(width: 320)
      Text("本工具不会修改飞连应用本身。停止服务时需要管理员权限。")
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
        Image(systemName: controller.state.symbol)
          .font(.title2)
          .foregroundStyle(controller.state.color)
        VStack(alignment: .leading, spacing: 2) {
          Text(controller.state.title).font(.headline)
          Text(controller.state.detail).font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack {
        Button("启动") { controller.perform("start") }
          .disabled(controller.isBusy || controller.state.isRunning)
        Button("停止") { controller.perform("stop") }
          .disabled(controller.isBusy || controller.state.isStopped)
        Button("刷新") { controller.refresh() }
          .disabled(controller.isBusy)
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

    MenuBarExtra("飞连控制", systemImage: controller.state.symbol, isInserted: $showMenuBarItem) {
      MenuBarView(controller: controller)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .frame(width: 560, height: 360)
    }
  }
}
