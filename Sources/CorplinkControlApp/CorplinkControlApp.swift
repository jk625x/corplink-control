import AppKit
import Combine
import CorplinkControlCore
import Darwin
import LocalAuthentication
import ServiceManagement
import SwiftUI

private enum AppConstants {
  static let languageKey = "appLanguage"
  static let keepRunningKey = "keepRunningAfterWindowClose"
  static let helperRegistrationFingerprintKey = "privilegedHelperRegistrationFingerprint-v1"
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

private func makeUnlinkedCaptureFile() -> FileHandle? {
  var template = Array("/tmp/corplink-control.XXXXXX".utf8CString)
  let descriptor = mkstemp(&template)
  guard descriptor >= 0 else { return nil }
  _ = unlink(template)
  return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func readCaptureFile(_ file: FileHandle) -> String {
  do {
    try file.seek(toOffset: 0)
    return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
  } catch {
    return ""
  }
}

private func runProcess(
  _ executable: URL, arguments: [String], environment: [String: String] = [:],
  timeout: TimeInterval? = nil
) async -> CommandResult {
  await Task.detached {
    let process = Process()
    guard let stdoutFile = makeUnlinkedCaptureFile(), let stderrFile = makeUnlinkedCaptureFile()
    else {
      return CommandResult(
        status: 71, stdout: "", stderr: "Could not create command output capture files.")
    }
    process.executableURL = executable
    process.arguments = arguments
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    process.standardOutput = stdoutFile
    process.standardError = stderrFile
    do {
      try process.run()
    } catch {
      return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
    }
    var timedOut = false
    if let timeout {
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning, Date() < deadline {
        usleep(50_000)
      }
      if process.isRunning {
        timedOut = true
        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < terminationDeadline {
          usleep(50_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    process.waitUntilExit()
    let stdout = readCaptureFile(stdoutFile)
    let stderr = readCaptureFile(stderrFile)
    if timedOut {
      return CommandResult(
        status: 124, stdout: stdout,
        stderr: stderr.isEmpty ? "The command timed out." : stderr)
    }
    return CommandResult(
      status: process.terminationStatus,
      stdout: stdout,
      stderr: stderr
    )
  }.value
}

private enum PrivilegedExecutionMode: Equatable {
  case xpc
  case administratorPrompt
}

private enum PrivilegedHelperAttempt {
  case completed(CommandResult)
  case fallbackAllowed(CommandResult)
  case deliveryUncertain(CommandResult)
}

private enum PrivilegedExecutionPreparation {
  case ready(mode: PrivilegedExecutionMode, migrationNotice: String?)
  case cancelled(CommandResult)
}

private func currentProcessIsAdministrator() -> Bool {
  if geteuid() == 0 { return true }
  let groupCount = getgroups(0, nil)
  guard groupCount > 0 else { return false }
  var groups = [gid_t](repeating: 0, count: Int(groupCount))
  return getgroups(groupCount, &groups) == groupCount
    && groups.contains(gid_t(PrivilegedHelperConfiguration.administratorGroupID))
}

private func currentHelperRegistrationFingerprint() -> String? {
  guard
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
    let resourcesURL = Bundle.main.resourceURL,
    let appRequirement = PrivilegedHelperConfiguration.designatedRequirement(
      at: Bundle.main.bundleURL)
  else { return nil }
  let helperURL = resourcesURL.appendingPathComponent("corplink-root-helper", isDirectory: false)
  guard
    let helperRequirement = PrivilegedHelperConfiguration.designatedRequirement(at: helperURL)
  else { return nil }
  return PrivilegedHelperConfiguration.registrationFingerprint(
    bundleVersion: build, appRequirement: appRequirement,
    helperRequirement: helperRequirement)
}

private func registeredHelperMatchesCurrentBuild() -> Bool {
  guard let currentFingerprint = currentHelperRegistrationFingerprint() else { return false }
  return UserDefaults.standard.string(forKey: AppConstants.helperRegistrationFingerprintKey)
    == currentFingerprint
}

private func recordCurrentHelperRegistration() {
  guard let fingerprint = currentHelperRegistrationFingerprint() else { return }
  UserDefaults.standard.set(fingerprint, forKey: AppConstants.helperRegistrationFingerprintKey)
}

private func clearRecordedHelperRegistration() {
  UserDefaults.standard.removeObject(forKey: AppConstants.helperRegistrationFingerprintKey)
}

private func authenticateHelperRegistration(
  _ language: AppLanguage, upgrading: Bool = false
) async -> Bool {
  let context = LAContext()
  context.localizedCancelTitle = text(language, "Cancel", "取消")
  let reason = upgrading
    ? text(
      language,
      "Authenticate to update passwordless Corplink control for this administrator account.",
      "请验证身份，以便为当前管理员账户升级飞连免密码控制。")
    : text(
      language,
      "Authenticate to enable passwordless Corplink control for this administrator account.",
      "请验证身份，以便为当前管理员账户开启飞连免密码控制。")
  return (try? await context.evaluatePolicy(
    .deviceOwnerAuthentication, localizedReason: reason)) == true
}

private func waitForPrivilegedHelperUnregistration(timeout: TimeInterval = 15) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  var inactiveSince: Date?
  while Date() < deadline {
    let status = SMAppService.daemon(
      plistName: PrivilegedHelperConfiguration.daemonPlistName).status
    let launchctlResult = await runProcess(
      URL(fileURLWithPath: "/bin/launchctl"),
      arguments: ["print", "system/\(PrivilegedHelperConfiguration.machServiceName)"],
      timeout: 2)
    let serviceManagementInactive: Bool
    switch status {
    case .notRegistered, .notFound:
      serviceManagementInactive = true
    case .enabled, .requiresApproval:
      serviceManagementInactive = false
    @unknown default:
      return false
    }
    let decision = HelperUnregistrationDecision.evaluate(
      serviceManagementInactive: serviceManagementInactive,
      launchctlExitStatus: launchctlResult.status)
    switch decision {
    case .complete:
      if inactiveSince == nil { inactiveSince = Date() }
      if let inactiveSince, Date().timeIntervalSince(inactiveSince) >= 0.5 { return true }
    case .waiting, .inspectionFailed:
      inactiveSince = nil
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
  }
  return false
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
  @Published var isWarning = false
  @Published var progressMessage: String?
  @Published var vpnStatus = "unknown"
  @Published var swgStatus = "unknown"
  @Published var components = ComponentStatus.definitions
  @Published var activeSystemExtensions: [String] = []
  @Published var suiteClean = false
  @Published var suiteRuntimeStopped = false
  @Published var suiteLoaded = 0
  @Published var suiteTotal = ComponentStatus.definitions.count
  @Published var suiteKnownTotal = ComponentStatus.definitions.count
  @Published var suiteProcesses = 0
  @Published var restorePending: [String] = []
  @Published var auxiliaryComponents: [String] = []
  @Published var auxiliaryPIDs: [Int32] = []
  @Published var clientAppPresent = false
  @Published var clientAppRunning = false
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
    if suiteRuntimeStopped {
      return text(language, "Corplink runtime is stopped", "飞连运行组件已停止")
    }
    if suiteLoaded == 0 { return text(language, "Corplink state is inconsistent", "飞连状态异常") }
    return text(language, "Corplink is running", "飞连运行中")
  }

  var suiteDetail: String {
    if !hasStatus { return "" }
    if suiteRuntimeStopped, !activeSystemExtensions.isEmpty {
      return text(
        language,
        "No jobs or processes running · \(activeSystemExtensions.count) System Extension enabled",
        "无任务或进程运行 · \(activeSystemExtensions.count) 个 System Extension 仍启用")
    }
    return text(
      language,
      "\(suiteLoaded) / \(suiteTotal) services loaded · \(suiteProcesses) processes",
      "已加载 \(suiteLoaded) / \(suiteTotal) 个服务 · \(suiteProcesses) 个进程")
  }

  var suiteSymbol: String {
    if !hasStatus { return "arrow.clockwise" }
    if suiteClean { return "shield.slash" }
    if suiteRuntimeStopped { return "exclamationmark.shield.fill" }
    if suiteLoaded > 0 { return "checkmark.shield.fill" }
    return "exclamationmark.shield.fill"
  }

  var suiteColor: Color {
    if !hasStatus { return .secondary }
    if suiteClean { return .secondary }
    if suiteRuntimeStopped { return .orange }
    if suiteLoaded > 0 { return .green }
    return .orange
  }

  var isWorking: Bool { isBusy }

  var canStartSuite: Bool {
    components.contains { !$0.loaded && $0.present && !$0.disabled }
      || (clientAppPresent && !clientAppRunning)
  }

  private var helperURL: URL? {
    guard let resourcesURL = Bundle.main.resourceURL else { return nil }
    let url = resourcesURL.appendingPathComponent("corplink-root-helper", isDirectory: false)
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  private func privilegedExecutionMode() -> PrivilegedExecutionMode {
    let service = SMAppService.daemon(
      plistName: PrivilegedHelperConfiguration.daemonPlistName)
    guard
      service.status == .enabled,
      currentProcessIsAdministrator(),
      registeredHelperMatchesCurrentBuild()
    else {
      return .administratorPrompt
    }

    let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard
      appURL.deletingLastPathComponent() == applicationsURL,
      PrivilegedHelperConfiguration.designatedRequirement(at: appURL) != nil
    else { return .administratorPrompt }
    return .xpc
  }

  private func preparePrivilegedExecution(
    helperURL: URL, language: AppLanguage
  ) async -> PrivilegedExecutionPreparation {
    let currentMode = privilegedExecutionMode()
    if case .xpc = currentMode { return .ready(mode: .xpc, migrationNotice: nil) }

    let service = SMAppService.daemon(
      plistName: PrivilegedHelperConfiguration.daemonPlistName)
    switch service.status {
    case .enabled, .requiresApproval:
      break
    default:
      return .ready(mode: .administratorPrompt, migrationNotice: nil)
    }
    guard !registeredHelperMatchesCurrentBuild() else {
      return .ready(mode: .administratorPrompt, migrationNotice: nil)
    }

    let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard
      currentProcessIsAdministrator(),
      appURL.deletingLastPathComponent() == applicationsURL,
      PrivilegedHelperConfiguration.designatedRequirement(at: appURL) != nil,
      PrivilegedHelperConfiguration.designatedRequirement(at: helperURL) != nil,
      currentHelperRegistrationFingerprint() != nil
    else {
      return .ready(
        mode: .administratorPrompt,
        migrationNotice: text(
          language,
          "The registered helper belongs to another build and could not be migrated safely. Password authorization was used.",
          "已注册 helper 属于其他构建，无法安全迁移；本次改用密码授权。"))
    }

    guard await authenticateHelperRegistration(language, upgrading: true) else {
      return .cancelled(
        CommandResult(
          status: -128, stdout: "",
          stderr: text(
            language,
            "Helper update authentication was cancelled; no control action was sent.",
            "已取消 helper 升级认证，未发送任何控制操作。")))
    }

    do {
      try await service.unregister()
      clearRecordedHelperRegistration()
      guard await waitForPrivilegedHelperUnregistration() else {
        return .ready(
          mode: .administratorPrompt,
          migrationNotice: text(
            language,
            "The old passwordless helper did not finish unregistering. This action used administrator-password authorization; no new helper was registered yet.",
            "旧版免密码 helper 未完成注销；本次改用管理员密码授权，且尚未注册新 helper。"))
      }
      let replacementService = SMAppService.daemon(
        plistName: PrivilegedHelperConfiguration.daemonPlistName)
      try replacementService.register()
      recordCurrentHelperRegistration()
    } catch {
      clearRecordedHelperRegistration()
      return .ready(
        mode: .administratorPrompt,
        migrationNotice: text(
          language,
          "The passwordless helper update failed; this action used administrator-password authorization instead. \(error.localizedDescription)",
          "免密码 helper 升级失败，本次改用管理员密码授权。\(error.localizedDescription)"))
    }

    let migratedMode = privilegedExecutionMode()
    let notice =
      migratedMode == .xpc
      ? text(
        language,
        "The passwordless helper was registered for this app build and is being verified before use.",
        "已为当前 App 构建注册免密码 helper，使用前正在验证。")
      : text(
        language,
        "The updated helper is waiting for approval in System Settings; this action used administrator-password authorization.",
        "新版 helper 正等待在系统设置中批准，本次改用管理员密码授权。")
    return .ready(mode: migratedMode, migrationNotice: notice)
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
        environment: ["CORPLINK_CONTROL_LANG": language.helperCode], timeout: 15)
      guard requestID == statusRequestID else { return }
      if !isBusy, result.status != 124 {
        applyStatus(result)
      } else if !isBusy {
        showMessage(
          text(
            language, "Status refresh timed out. The displayed state was left unchanged.",
            "状态刷新超时，当前显示状态未被更改。"),
          error: true)
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
    isWarning = false
    progressMessage = text(language, "Preparing the control request…", "正在准备控制请求…")
    Task {
      defer {
        progressMessage = nil
        isBusy = false
      }
      guard PrivilegedHelperConfiguration.allowedActions.contains(action) else {
        showMessage(text(language, "Unsupported control action.", "不支持的控制操作。"), error: true)
        return
      }
      let preparation = await preparePrivilegedExecution(
        helperURL: helperURL, language: language)
      let executionMode: PrivilegedExecutionMode
      let migrationNotice: String?
      switch preparation {
      case .ready(let mode, let notice):
        executionMode = mode
        migrationNotice = notice
      case .cancelled(let cancellation):
        showMessage(cancellation.stderr, error: true)
        return
      }
      let shouldDisconnect =
        action == "stop" || action == "stop-suite"
        || action == "stop-component:connection"
      let currentLanguage = language
      if shouldDisconnect {
        progressMessage = text(
          currentLanguage, "Disconnecting active VPN and SWG sessions…", "正在断开 VPN 和 SWG 会话…")
      }
      let disconnectSummary =
        shouldDisconnect ? await Self.disconnectNetworkSessions(language: currentLanguage) : nil
      progressMessage = operationProgressText(action, language: currentLanguage)
      let result: CommandResult
      var executionNotice: String?
      var shouldRefreshStatus = true
      switch executionMode {
      case .xpc:
        let attempt = await Self.runWithPrivilegedHelper(
          helperURL: helperURL, action: action, language: currentLanguage)
        switch attempt {
        case .completed(let helperResult):
          result = helperResult
          if migrationNotice != nil {
            executionNotice = text(
              currentLanguage,
              "The passwordless helper was updated and verified for this app build.",
              "免密码 helper 已迁移并通过当前 App 构建验证。")
          }
        case .fallbackAllowed:
          clearRecordedHelperRegistration()
          executionNotice = text(
            currentLanguage,
            "The registered passwordless helper did not pass its health check; this action used administrator-password authorization.",
            "已注册的免密码 helper 未通过健康检查；本次改用管理员密码授权。")
          progressMessage = text(
            currentLanguage,
            "The passwordless helper is unavailable; waiting for administrator authorization…",
            "免密码 helper 不可用，正在等待管理员授权…")
          result = await Self.runWithAdministratorPrivileges(
            helperURL, action: action, language: currentLanguage)
        case .deliveryUncertain(let helperResult):
          shouldRefreshStatus = false
          let guidance = text(
            currentLanguage,
            "The request may have reached the privileged helper, so it was not repeated "
              + "automatically. Refresh status first. To retry with an administrator password, "
              + "turn off Passwordless start and stop and try again.",
            "请求可能已经送达特权 helper，因此没有自动重复执行。请先刷新状态；"
              + "如需改用管理员密码重试，请关闭“免密码启停”后再次操作。")
          let detail = helperResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
          result = CommandResult(
            status: helperResult.status,
            stdout: helperResult.stdout,
            stderr: detail.isEmpty ? guidance : "\(detail)\n\(guidance)")
        }
      case .administratorPrompt:
        progressMessage = text(
          currentLanguage, "Waiting for administrator authorization…", "正在等待管理员授权…")
        result = await Self.runWithAdministratorPrivileges(
          helperURL, action: action, language: currentLanguage)
      }
      let operationNotice = executionNotice ?? migrationNotice
      if result.status == 0 {
        let outputText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let warning = outputText.split(separator: "\n").contains { line in
          line.hasPrefix("Warning:") || line.hasPrefix("提示：")
        }
        let parts = [
          operationNotice,
          disconnectSummary,
          outputText.isEmpty
            ? text(currentLanguage, "Operation completed successfully", "操作成功") : outputText,
        ].compactMap { $0 }
        showMessage(parts.joined(separator: "\n"), error: false, warning: warning)
      } else {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = detail.contains("User canceled") || detail.contains("(-128)")
        showMessage(
          cancelled
            ? text(currentLanguage, "Administrator authorization was cancelled", "已取消管理员授权")
            : (detail.isEmpty
              ? text(currentLanguage, "Operation failed", "操作失败")
              : cleanAdministratorError(detail)),
          error: true)
        if let operationNotice {
          message = [operationNotice, message].compactMap { $0 }.joined(separator: "\n")
        }
      }
      if shouldRefreshStatus {
        progressMessage = text(
          currentLanguage, "Verifying the live Corplink state…", "正在验证飞连实时状态…")
        let statusResult = await Self.run(
          helperURL, arguments: ["status"],
          environment: ["CORPLINK_CONTROL_LANG": currentLanguage.helperCode], timeout: 15)
        if statusResult.status != 124 {
          applyStatus(statusResult)
        } else {
          let warning = text(
            currentLanguage,
            "The operation returned, but status refresh timed out. Refresh status again before another control action.",
            "操作已返回，但状态刷新超时。再次控制前请重新刷新状态。")
          message = [message, warning].compactMap { $0 }.joined(separator: "\n")
          isWarning = true
        }
      }
    }
  }

  private func operationProgressText(_ action: String, language: AppLanguage) -> String {
    if action == "stop-suite" {
      return text(
        language,
        "Stopping all Corplink components and checking for restarts…",
        "正在停止所有飞连组件并检查是否复活…")
    }
    if action == "start-suite" {
      return text(language, "Starting and verifying all Corplink components…", "正在启动并验证所有飞连组件…")
    }
    if action.hasPrefix("stop") {
      return text(language, "Stopping and verifying the component…", "正在停止并验证组件…")
    }
    return text(language, "Starting and verifying the component…", "正在启动并验证组件…")
  }

  private func applyStatus(_ result: CommandResult) {
    let report: HelperStatusReport
    do {
      report = try HelperStatusReport.parse(exitStatus: result.status, output: result.stdout)
    } catch {
      showMessage(
        text(
          language,
          "The helper returned an invalid status report. The displayed state was left unchanged. \(error)",
          "helper 返回了无效状态报告，当前显示状态未更改。\(error)"),
        error: true)
      return
    }
    let values = report.values
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
    suiteRuntimeStopped = values["suite_runtime_stopped"] == "true"
    suiteLoaded = Int(values["suite_loaded"] ?? "") ?? 0
    suiteTotal = Int(values["suite_total"] ?? "") ?? ComponentStatus.definitions.count
    suiteKnownTotal = Int(values["suite_known_total"] ?? "") ?? ComponentStatus.definitions.count
    suiteProcesses = Int(values["suite_processes"] ?? "") ?? 0
    restorePending = (values["restore_pending"] ?? "").split(separator: ",").map(String.init)
    auxiliaryComponents = (values["auxiliary_components"] ?? "").split(separator: ",").map(
      String.init)
    auxiliaryPIDs = (values["auxiliary_pids"] ?? "").split(separator: ",").compactMap { Int32($0) }
    activeSystemExtensions = (values["system_extensions"] ?? "").split(separator: ",").map(
      String.init)
    clientAppPresent = values["client_app_present"] == "true"
    clientAppRunning = values["client_app_running"] == "true"
    hasStatus = true

    if loaded, !pids.isEmpty {
      state = .running(pids)
    } else if !loaded, pids.isEmpty {
      state = .stopped
    } else {
      state = .inconsistent(loaded: loaded, pids: pids)
    }
  }

  private func showMessage(_ text: String, error: Bool, warning: Bool = false) {
    message = text
    isError = error
    isWarning = warning
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

    async let vpnRequest = run(cliURL, arguments: ["vpn", "disconnect"], timeout: 5)
    async let swgRequest = run(cliURL, arguments: ["swg", "disconnect"], timeout: 5)
    let (vpnResult, swgResult) = await (vpnRequest, swgRequest)
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
    _ executable: URL, arguments: [String], environment: [String: String] = [:],
    timeout: TimeInterval? = nil
  ) async -> CommandResult
  {
    await runProcess(
      executable, arguments: arguments, environment: environment, timeout: timeout)
  }

  nonisolated private static func runWithPrivilegedHelper(
    helperURL: URL, action: String, language: AppLanguage
  ) async -> PrivilegedHelperAttempt {
    guard
      let helperRequirement = PrivilegedHelperConfiguration.designatedRequirement(at: helperURL),
      let expectedBundleVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion") as? String
    else {
      return .fallbackAllowed(
        CommandResult(
          status: 78, stdout: "",
          stderr: "The privileged helper does not have a valid designated requirement."))
    }
    return await withCheckedContinuation { continuation in
      let connection = NSXPCConnection(
        machServiceName: PrivilegedHelperConfiguration.machServiceName,
        options: .privileged)
      connection.remoteObjectInterface = NSXPCInterface(
        with: CorplinkPrivilegedHelperProtocol.self)
      connection.setCodeSigningRequirement(helperRequirement)

      let lock = NSLock()
      var completed = false
      var requestSubmitted = false
      func finish(_ attempt: PrivilegedHelperAttempt) {
        lock.lock()
        guard !completed else {
          lock.unlock()
          return
        }
        completed = true
        lock.unlock()
        connection.invalidate()
        continuation.resume(returning: attempt)
      }

      func finishTransportFailure(_ result: CommandResult) {
        lock.lock()
        guard !completed else {
          lock.unlock()
          return
        }
        let attempt: PrivilegedHelperAttempt =
          PrivilegedHelperConfiguration.canFallbackAfterTransportFailure(
            requestSubmitted: requestSubmitted)
          ? .fallbackAllowed(result) : .deliveryUncertain(result)
        completed = true
        lock.unlock()
        connection.invalidate()
        continuation.resume(returning: attempt)
      }

      func markRequestSubmitted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        requestSubmitted = true
        return true
      }

      connection.interruptionHandler = {
        finishTransportFailure(
          CommandResult(
            status: 70, stdout: "",
            stderr: "The privileged helper connection was interrupted."))
      }
      connection.invalidationHandler = {
        finishTransportFailure(
          CommandResult(
            status: 70, stdout: "",
            stderr: "The privileged helper connection became invalid."))
      }
      connection.activate()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          finishTransportFailure(
            CommandResult(status: 70, stdout: "", stderr: error.localizedDescription))
        }) as? CorplinkPrivilegedHelperProtocol
      else {
        finishTransportFailure(
          CommandResult(
            status: 70, stdout: "", stderr: "The privileged helper proxy is unavailable."))
        return
      }

      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
        lock.lock()
        let stillProbing = !completed && !requestSubmitted
        lock.unlock()
        if stillProbing {
          finishTransportFailure(
            CommandResult(
              status: 124, stdout: "",
              stderr: "The privileged helper did not answer its health probe."))
        }
      }

      proxy.probe { protocolVersion, bundleVersion in
        guard
          PrivilegedHelperConfiguration.isCompatibleProbe(
            protocolVersion: protocolVersion.intValue,
            bundleVersion: bundleVersion,
            expectedBundleVersion: expectedBundleVersion)
        else {
          finish(
            .fallbackAllowed(
              CommandResult(
                status: 78, stdout: "",
                stderr:
                  "The registered privileged helper did not match this app build or protocol.")))
          return
        }
        guard markRequestSubmitted() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
          finishTransportFailure(
            CommandResult(
              status: 124, stdout: "",
              stderr: "The privileged helper did not reply before the operation timeout."))
        }
        proxy.perform(action: action, language: language.helperCode) { status, stdout, stderr in
          finish(
            .completed(
              CommandResult(status: status.int32Value, stdout: stdout, stderr: stderr)))
        }
      }
    }
  }

  nonisolated private static func runWithAdministratorPrivileges(
    _ helper: URL, action: String, language: AppLanguage
  ) async -> CommandResult {
    guard PrivilegedHelperConfiguration.allowedActions.contains(action) else {
      return CommandResult(status: 64, stdout: "", stderr: "Unsupported control action.")
    }
    let command =
      "CORPLINK_CONTROL_LANG=\(shellQuote(language.helperCode)) \(shellQuote(helper.path)) \(shellQuote(action))"
    let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
    return await run(
      URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: 180)
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
private final class PrivilegedHelperController: ObservableObject {
  private enum Status: Equatable {
    case checking, enabled, updateRequired, requiresApproval, notRegistered, notFound, unknown
  }

  @Published var isEnabled = false
  @Published var isChanging = false
  @Published private var status: Status = .checking
  @Published var errorMessage: String?

  private var service: SMAppService {
    SMAppService.daemon(plistName: PrivilegedHelperConfiguration.daemonPlistName)
  }

  init() {
    refresh()
  }

  func refresh() {
    switch service.status {
    case .enabled:
      isEnabled = true
      status = registeredHelperMatchesCurrentBuild() ? .enabled : .updateRequired
    case .requiresApproval:
      isEnabled = true
      status = registeredHelperMatchesCurrentBuild() ? .requiresApproval : .updateRequired
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
    if isChanging { return text(language, "Authenticating…", "正在验证身份…") }
    switch status {
    case .checking: return text(language, "Checking…", "正在检查…")
    case .enabled: return text(language, "Enabled", "已启用")
    case .updateRequired:
      return text(
        language, "Update required before the next passwordless action",
        "下次免密码操作前需要升级 helper")
    case .requiresApproval:
      return text(language, "Waiting for approval in System Settings", "等待在系统设置中批准")
    case .notRegistered: return text(language, "Not enabled", "未启用")
    case .notFound: return text(language, "Helper not found in this app", "当前 App 中找不到 helper")
    case .unknown: return text(language, "Unknown status", "未知状态")
    }
  }

  var requiresApproval: Bool { status == .requiresApproval }

  func setEnabled(_ enabled: Bool, language: AppLanguage) {
    guard !isChanging else { return }
    errorMessage = nil
    if enabled {
      let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
      let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      guard appURL.deletingLastPathComponent() == applicationsURL else {
        errorMessage = text(
          language,
          "Move this app to /Applications and replace the old copy before enabling passwordless control.",
          "请先把当前 App 移到 /Applications 并替换旧版本，再开启免密码控制。")
        refresh()
        return
      }
      let helperURL = appURL.appendingPathComponent(
        "Contents/Resources/corplink-root-helper", isDirectory: false)
      let daemonPlistURL = appURL.appendingPathComponent(
        "Contents/Library/LaunchDaemons/\(PrivilegedHelperConfiguration.daemonPlistName)",
        isDirectory: false)
      guard
        FileManager.default.isExecutableFile(atPath: helperURL.path),
        FileManager.default.fileExists(atPath: daemonPlistURL.path),
        PrivilegedHelperConfiguration.designatedRequirement(at: appURL) != nil,
        PrivilegedHelperConfiguration.designatedRequirement(at: helperURL) != nil
      else {
        errorMessage = text(
          language,
          "This app copy is incomplete or its signature is invalid. Install a fresh build.",
          "当前 App 不完整或签名无效，请安装一份新的构建。")
        refresh()
        return
      }
      guard currentProcessIsAdministrator() else {
        errorMessage = text(
          language,
          "Only the foreground administrator account can enable passwordless control.",
          "只有当前前台管理员账户可以开启免密码控制。")
        refresh()
        return
      }
      isChanging = true
      Task {
        defer { isChanging = false }
        guard await authenticateHelperRegistration(language) else {
          errorMessage = text(
            language, "Administrator authentication was cancelled or failed.",
            "管理员身份验证已取消或失败。")
          refresh()
          return
        }
        await updateRegistration(enabled: true, language: language)
      }
      return
    }

    isChanging = true
    Task {
      defer { isChanging = false }
      await updateRegistration(enabled: false, language: language)
    }
  }

  private func updateRegistration(enabled: Bool, language: AppLanguage) async {
    do {
      if enabled {
        let registrationService = SMAppService.daemon(
          plistName: PrivilegedHelperConfiguration.daemonPlistName)
        try registrationService.register()
        recordCurrentHelperRegistration()
      } else {
        try await service.unregister()
        clearRecordedHelperRegistration()
        guard await waitForPrivilegedHelperUnregistration() else {
          refresh()
          errorMessage = text(
            language,
            "macOS did not finish unregistering the privileged helper before the timeout. Passwordless actions remain disabled in this app; refresh the status before trying again.",
            "macOS 未在超时前完成特权 helper 注销。本 App 已禁用免密码操作；请刷新状态后再试。")
          return
        }
      }
    } catch {
      refresh()
      let expectedState = enabled ? (status == .enabled || status == .requiresApproval) : false
      if !expectedState { errorMessage = error.localizedDescription }
      return
    }
    refresh()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
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
        Text(controller.progressMessage ?? controller.suiteDetail)
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
        .disabled(controller.isWorking || controller.suiteRuntimeStopped)

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
          message,
          systemImage: controller.isError
            ? "xmark.circle.fill"
            : (controller.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        )
        .font(.callout)
        .foregroundStyle(
          controller.isError ? Color.red : (controller.isWarning ? Color.orange : Color.secondary)
        )
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
                : (controller.suiteRuntimeStopped
                  ? text(
                    controller.language, "Runtime stopped; System Extension enabled",
                    "运行组件已停止；System Extension 仍启用")
                  : text(controller.language, "Components are running", "有组件运行")))
            InfoRow(
              label: text(controller.language, "Installed jobs loaded", "已安装任务加载数"),
              value: "\(controller.suiteLoaded) / \(controller.suiteTotal)")
            InfoRow(
              label: text(controller.language, "Known job definitions", "已知任务定义"),
              value: String(controller.suiteKnownTotal))
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
              "Stop removes and verifies installed jobs and related processes. Start skips absent legacy jobs and launches an installed CorpLink or SealSuite client app when no legacy client LaunchAgent exists. Network Monitor is re-registered with the original Corplink plist. Active system extensions are not uninstalled and are reported as a warning after the runtime stops.",
              "停止整套会逐项卸载并验证已安装任务和相关进程；开始整套会跳过不存在的旧版任务。没有旧版客户端 LaunchAgent 时，将启动已安装的 CorpLink 或 SealSuite 客户端 App。网络监控使用飞连原始 plist 重新注册。活跃 System Extension 不会被卸载，运行组件停止后会作为提示展示。")
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
  @StateObject private var privilegedHelperController = PrivilegedHelperController()
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

        GroupBox(text(controller.language, "Privileged control", "特权控制")) {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              text(controller.language, "Passwordless start and stop", "免密码启停"),
              isOn: Binding(
                get: { privilegedHelperController.isEnabled },
                set: {
                  privilegedHelperController.setEnabled($0, language: controller.language)
                }
              )
            )
            .disabled(privilegedHelperController.isChanging)
            Text(
              "\(text(controller.language, "Current status", "当前状态")): \(privilegedHelperController.statusText(controller.language))")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(
              text(
                controller.language,
                "Off: each action requires an administrator password. On: after macOS approval, "
                  + "the foreground administrator can start or stop without repeated prompts. "
                  + "Re-enabling or upgrading requires authentication again.",
                "关闭时，每次操作需输入管理员密码；开启并经系统批准后，当前前台管理员可免密启停。"
                  + "重新开启或升级时需再次验证。"))
              .font(.caption)
              .foregroundStyle(.secondary)

            HStack {
              if privilegedHelperController.requiresApproval {
                Button(text(controller.language, "Open Approval Settings", "打开批准设置")) {
                  privilegedHelperController.openSystemSettings()
                }
              }
              Button(text(controller.language, "Refresh Status", "刷新状态")) {
                privilegedHelperController.refresh()
              }
            }
            if let error = privilegedHelperController.errorMessage {
              Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
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
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in
      privilegedHelperController.refresh()
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
    if controller.suiteRuntimeStopped { return .stopped }
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
