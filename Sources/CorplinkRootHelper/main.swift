import CorplinkControlCore
import Darwin
import Dispatch
import Foundation

private let environmentUsesChinese =
  ProcessInfo.processInfo.environment["CORPLINK_CONTROL_LANG"] == "zh-Hans"
private var daemonUsesChinese: Bool?

private var usesChinese: Bool { daemonUsesChinese ?? environmentUsesChinese }

private func message(_ english: String, _ chinese: String) -> String {
  usesChinese ? chinese : english
}

private enum JobDomain: Sendable { case system, gui }

private struct ManagedJob: Sendable {
  let id: String
  let englishName: String
  let chineseName: String
  let label: String
  let domain: JobDomain
  let plistPath: String
  let processPattern: String
  let launchOnlyOnce: Bool
  let expectsResidentProcess: Bool

  var name: String { message(englishName, chineseName) }

  func domainName(uid: uid_t) -> String {
    domain == .system ? "system" : "gui/\(uid)"
  }

  func target(uid: uid_t) -> String { "\(domainName(uid: uid))/\(label)" }
}

private let jobs = [
  ManagedJob(
    id: "connection", englishName: "Connection Service", chineseName: "连接主服务",
    label: "com.volcengine.corplink.service",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.volcengine.corplink.service.plist",
    processPattern: "^/usr/local/corplink/corplink-service([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "protection", englishName: "System Protection", chineseName: "系统防护",
    label: "com.volcengine.corplink.systemextension",
    domain: .system,
    plistPath: "/Library/LaunchDaemons/com.volcengine.corplink.systemextension.plist",
    processPattern: "^/Library/CorpLink/", launchOnlyOnce: false,
    expectsResidentProcess: true),
  ManagedJob(
    id: "network-monitor", englishName: "Network Monitor", chineseName: "网络监控",
    label: "com.corplink.networkmonitor",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.corplink.networkmonitor.plist",
    processPattern: "^/usr/local/corplink/bin/NetworkMonitor([[:space:]]|$)",
    launchOnlyOnce: true, expectsResidentProcess: true),
  ManagedJob(
    id: "data-forwarder", englishName: "Policy Data Forwarder", chineseName: "策略数据转发",
    label: "com.corplink.data_forwarder",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.corplink.data_forwarder.plist",
    processPattern: "^/usr/local/corplink/mdm/.+policy_data_forwarder\\.rb([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: false),
  ManagedJob(
    id: "mdm", englishName: "MDM Policy", chineseName: "MDM 策略",
    label: "com.corplink.mdm.policy", domain: .system,
    plistPath: "/Library/LaunchDaemons/com.corplink.mdm.policy.plist",
    processPattern: "^/usr/local/corplink/mdm/.+/clpolicy agent([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "network-agent", englishName: "Network Extension Agent", chineseName: "网络扩展代理",
    label: "com.volcengine.corplink.agent",
    domain: .gui, plistPath: "/Library/LaunchAgents/com.volcengine.corplink.agent.plist",
    processPattern:
      "^/Applications/CorpLink\\.app/Contents/Frameworks/CorplinkNe\\.app/Contents/MacOS/CorplinkNe([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "app-blocker", englishName: "Application Control", chineseName: "应用管控",
    label: "com.corplink.appblocker", domain: .gui,
    plistPath: "/Library/LaunchAgents/com.corplink.appblocker.plist",
    processPattern: "^/usr/local/corplink/bin/appblocker([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "client", englishName: "Client Login Item", chineseName: "客户端登录项",
    label: "CorpLink", domain: .gui,
    plistPath: "~/Library/LaunchAgents/CorpLink.plist",
    processPattern: "^/Applications/CorpLink\\.app/Contents/MacOS/CorpLink([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: false),
]

private let snapshotPath = "/Library/Application Support/CorplinkControl/restore-state.json"
private let auxiliaryProcessPatterns: [(englishName: String, chineseName: String, pattern: String)] = [
  (
    "Finder Sync", "Finder 同步扩展",
    "^/Applications/(CorpLink|SealSuite)\\.app/.+/CorpLink Finder Sync([[:space:]]|$)"
  ),
  ("SealSuite Client", "SealSuite 客户端", "^/Applications/SealSuite\\.app/Contents/MacOS/SealSuite([[:space:]]|$)"),
  (
    "Client Wi-Fi Helper", "客户端 Wi-Fi Helper",
    "^/Applications/(CorpLink|SealSuite)\\.app/Contents/MacOS/wifihelper([[:space:]]|$)"
  ),
]
private let clientApplications: [(name: String, path: String, processPattern: String)] = [
  (
    "CorpLink", "/Applications/CorpLink.app",
    "^/Applications/CorpLink\\.app/Contents/MacOS/CorpLink([[:space:]]|$)"
  ),
  (
    "SealSuite", "/Applications/SealSuite.app",
    "^/Applications/SealSuite\\.app/Contents/MacOS/SealSuite([[:space:]]|$)"
  ),
]

private struct RestoreSnapshot: Codable {
  var createdAt: Date
  var pendingJobIDs: Set<String>
  var savedPlists: [String: Data]? = nil
}

private struct CommandResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private struct InspectionFailure: Error {
  let english: String
  let chinese: String

  var localizedMessage: String { message(english, chinese) }
}

private func commandFailure(
  englishSubject: String, chineseSubject: String, result: CommandResult
) -> InspectionFailure {
  let rawDetail = result.stderr.isEmpty ? result.stdout : result.stderr
  let detail = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
  let englishReason =
    result.status == 124
    ? "the command timed out"
    : "the command exited with status \(result.status)"
  let chineseReason = result.status == 124 ? "命令超时" : "命令退出状态为 \(result.status)"
  let englishSuffix = detail.isEmpty ? "" : ": \(detail)"
  let chineseSuffix = detail.isEmpty ? "" : "：\(detail)"
  return InspectionFailure(
    english: "Could not inspect \(englishSubject): \(englishReason)\(englishSuffix)",
    chinese: "无法检查\(chineseSubject)：\(chineseReason)\(chineseSuffix)")
}

private func makeUnlinkedCaptureFile() -> FileHandle? {
  var template = Array("/tmp/corplink-control-helper.XXXXXX".utf8CString)
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

@discardableResult
private func run(
  _ executable: String, _ arguments: [String], timeout: TimeInterval = 10
) -> CommandResult {
  let process = Process()
  guard let stdoutFile = makeUnlinkedCaptureFile(), let stderrFile = makeUnlinkedCaptureFile()
  else {
    return CommandResult(
      status: 71, stdout: "", stderr: "Could not create command output capture files.")
  }
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = stdoutFile
  process.standardError = stderrFile
  do {
    try process.run()
  } catch {
    return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
  }
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  let timedOut = process.isRunning
  if timedOut {
    process.terminate()
    let terminationDeadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < terminationDeadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
  process.waitUntilExit()
  let stdout = readCaptureFile(stdoutFile)
  let stderr = readCaptureFile(stderrFile)
  if timedOut {
    return CommandResult(
      status: 124, stdout: stdout,
      stderr: stderr.isEmpty ? "The command timed out: \(executable)" : stderr)
  }
  return CommandResult(
    status: process.terminationStatus,
    stdout: stdout,
    stderr: stderr)
}

private func currentExecutablePath() -> String {
  var size = UInt32(PATH_MAX)
  var buffer = [CChar](repeating: 0, count: Int(size))
  if _NSGetExecutablePath(&buffer, &size) == 0 {
    return String(cString: buffer)
  }
  buffer = [CChar](repeating: 0, count: Int(size))
  if _NSGetExecutablePath(&buffer, &size) == 0 {
    return String(cString: buffer)
  }
  return CommandLine.arguments[0]
}

private func containingApplicationURL() -> URL? {
  var candidate = URL(fileURLWithPath: currentExecutablePath()).standardizedFileURL
  while candidate.path != "/" {
    if candidate.pathExtension == "app" { return candidate }
    candidate.deleteLastPathComponent()
  }
  return nil
}

private func captureCommand(_ action: String, language: String) -> CommandResult {
  guard let stdoutFile = makeUnlinkedCaptureFile(), let stderrFile = makeUnlinkedCaptureFile()
  else {
    return CommandResult(status: 71, stdout: "", stderr: "Could not capture helper output.")
  }
  let savedStdout = dup(STDOUT_FILENO)
  let savedStderr = dup(STDERR_FILENO)
  guard savedStdout >= 0, savedStderr >= 0 else {
    if savedStdout >= 0 { close(savedStdout) }
    if savedStderr >= 0 { close(savedStderr) }
    return CommandResult(status: 71, stdout: "", stderr: "Could not capture helper output.")
  }

  fflush(stdout)
  fflush(stderr)
  guard
    dup2(stdoutFile.fileDescriptor, STDOUT_FILENO) >= 0,
    dup2(stderrFile.fileDescriptor, STDERR_FILENO) >= 0
  else {
    _ = dup2(savedStdout, STDOUT_FILENO)
    _ = dup2(savedStderr, STDERR_FILENO)
    close(savedStdout)
    close(savedStderr)
    return CommandResult(status: 71, stdout: "", stderr: "Could not redirect helper output.")
  }

  daemonUsesChinese = language == "zh-Hans"
  let status = executeCommand(action)
  daemonUsesChinese = nil
  fflush(stdout)
  fflush(stderr)

  _ = dup2(savedStdout, STDOUT_FILENO)
  _ = dup2(savedStderr, STDERR_FILENO)
  close(savedStdout)
  close(savedStderr)

  return CommandResult(
    status: status,
    stdout: readCaptureFile(stdoutFile),
    stderr: readCaptureFile(stderrFile))
}

private final class PrivilegedHelperService: NSObject, CorplinkPrivilegedHelperProtocol {
  private static let operationQueue = DispatchQueue(
    label: "local.sunyi.corplink-control.root-helper.operations")
  private let bundleVersion: String

  init(bundleVersion: String) {
    self.bundleVersion = bundleVersion
    super.init()
  }

  func probe(withReply reply: @escaping (NSNumber, String) -> Void) {
    guard geteuid() == 0 else {
      reply(NSNumber(value: 0), "")
      return
    }
    reply(
      NSNumber(value: PrivilegedHelperConfiguration.protocolVersion),
      bundleVersion)
  }

  func perform(
    action: String,
    language: String,
    withReply reply: @escaping (NSNumber, String, String) -> Void
  ) {
    guard PrivilegedHelperConfiguration.allowedActions.contains(action) else {
      reply(NSNumber(value: 64), "", "The privileged helper rejected an unknown action.")
      return
    }
    guard geteuid() == 0 else {
      reply(NSNumber(value: 77), "", "The privileged helper is not running as root.")
      return
    }
    Self.operationQueue.async {
      let result = captureCommand(action, language: language)
      reply(NSNumber(value: result.status), result.stdout, result.stderr)
    }
  }
}

private final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let bundleVersion: String

  init(bundleVersion: String) {
    self.bundleVersion = bundleVersion
    super.init()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    let clientUID = connection.effectiveUserIdentifier
    guard
      geteuid() == 0,
      clientUID == consoleUID(),
      isAdministrator(uid: clientUID)
    else { return false }
    connection.exportedInterface = NSXPCInterface(with: CorplinkPrivilegedHelperProtocol.self)
    connection.exportedObject = PrivilegedHelperService(bundleVersion: bundleVersion)
    connection.activate()
    return true
  }
}

private func runPrivilegedDaemon() -> Never {
  guard geteuid() == 0 else {
    fputs("The privileged helper daemon must be launched by launchd as root.\n", stderr)
    exit(77)
  }
  guard
    let appURL = containingApplicationURL(),
    let appBundle = Bundle(url: appURL),
    appBundle.bundleIdentifier == PrivilegedHelperConfiguration.appBundleIdentifier,
    let bundleVersion = appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
    let appRequirement = PrivilegedHelperConfiguration.designatedRequirement(at: appURL)
  else {
    fputs("The containing app does not have a valid designated requirement.\n", stderr)
    exit(78)
  }
  let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.machServiceName)
  let delegate = PrivilegedHelperListenerDelegate(bundleVersion: bundleVersion)
  listener.delegate = delegate
  listener.setConnectionCodeSigningRequirement(appRequirement)
  listener.activate()
  dispatchMain()
}

private func consoleUID() -> uid_t {
  let result = run("/usr/bin/stat", ["-f", "%u", "/dev/console"], timeout: 2)
  return uid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? getuid()
}

private func isAdministrator(uid: uid_t) -> Bool {
  if uid == 0 { return true }
  let result = run(
    "/usr/bin/dsmemberutil",
    [
      "checkmembership", "-u", String(uid), "-g",
      String(PrivilegedHelperConfiguration.administratorGroupID),
    ], timeout: 3)
  return PrivilegedHelperConfiguration.isAdministratorMembershipResult(
    status: result.status, stdout: result.stdout)
}

private struct UserRecord {
  let name: String
  let homeDirectory: String
}

private func userRecord(for uid: uid_t) -> UserRecord? {
  var passwordEntry = passwd()
  var result: UnsafeMutablePointer<passwd>?
  let configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX)
  let bufferSize = configuredSize > 0 ? Int(configuredSize) : 16_384
  var buffer = [CChar](repeating: 0, count: bufferSize)
  guard
    getpwuid_r(uid, &passwordEntry, &buffer, buffer.count, &result) == 0,
    result != nil,
    let namePointer = passwordEntry.pw_name,
    let homePointer = passwordEntry.pw_dir
  else { return nil }
  return UserRecord(
    name: String(cString: namePointer), homeDirectory: String(cString: homePointer))
}

private func username(for uid: uid_t) -> String? {
  userRecord(for: uid)?.name
}

private func expandedPlistPath(for job: ManagedJob, uid: uid_t) -> String {
  guard job.plistPath.hasPrefix("~/") else { return job.plistPath }
  guard let homeDirectory = userRecord(for: uid)?.homeDirectory else { return job.plistPath }
  return homeDirectory + String(job.plistPath.dropFirst())
}

private func isLoaded(_ job: ManagedJob, uid: uid_t) throws -> Bool {
  let result = run("/bin/launchctl", ["print", job.target(uid: uid)], timeout: 2)
  switch LaunchctlPrintDecision.evaluate(exitStatus: result.status) {
  case .loaded: return true
  case .notLoaded: return false
  case .failed:
    throw commandFailure(
      englishSubject: "the launch state of \(job.name)",
      chineseSubject: "\(job.name) 的 launchd 加载状态", result: result)
  }
}

private func processPIDs(_ job: ManagedJob) throws -> [Int32] {
  try matchingPIDs(job.processPattern, englishSubject: job.name, chineseSubject: job.name)
}

private func matchingPIDs(
  _ pattern: String, englishSubject: String = "related processes",
  chineseSubject: String = "相关进程"
) throws -> [Int32] {
  let result = run("/usr/bin/pgrep", ["-f", pattern], timeout: 2)
  switch PgrepDecision.evaluate(exitStatus: result.status) {
  case .noMatches:
    return []
  case .failed:
    throw commandFailure(
      englishSubject: englishSubject, chineseSubject: chineseSubject, result: result)
  case .matches:
    let fields = result.stdout.split(whereSeparator: { $0.isWhitespace })
    let pids = fields.compactMap { Int32($0) }
    guard !fields.isEmpty, pids.count == fields.count else {
      throw InspectionFailure(
        english: "Could not inspect \(englishSubject): pgrep returned malformed output",
        chinese: "无法检查\(chineseSubject)：pgrep 返回了格式错误的结果")
    }
    return Array(Set(pids)).sorted()
  }
}

private func clientApplicationPIDs() throws -> [Int32] {
  var pids = Set<Int32>()
  for application in clientApplications {
    pids.formUnion(
      try matchingPIDs(
        application.processPattern, englishSubject: "the \(application.name) client process",
        chineseSubject: "\(application.name) 客户端进程"))
  }
  return pids.sorted()
}

private func installedClientApplication() -> (name: String, path: String, processPattern: String)? {
  clientApplications.first { FileManager.default.fileExists(atPath: $0.path) }
}

private enum ClientApplicationStartResult {
  case notInstalled
  case alreadyRunning
  case started(String)
  case failed(String)
}

private func startClientApplicationIfAvailable(uid: uid_t) throws -> ClientApplicationStartResult {
  if try !clientApplicationPIDs().isEmpty { return .alreadyRunning }
  guard let application = installedClientApplication() else { return .notInstalled }
  guard let username = username(for: uid) else {
    return .failed(
      message(
        "Client application: could not determine the console user",
        "客户端 App：无法确定当前登录用户"))
  }
  let result = run(
    "/bin/launchctl",
    [
      "asuser", String(uid), "/usr/bin/sudo", "-u", username, "/usr/bin/open", "-g", "-j",
      application.path,
    ])
  guard result.status == 0 else {
    return .failed(
      message(
        "\(application.name) client failed to launch: \(result.stderr)",
        "\(application.name) 客户端启动失败：\(result.stderr)"))
  }
  let deadline = Date().addingTimeInterval(8)
  while Date() < deadline {
    if try !matchingPIDs(
      application.processPattern, englishSubject: "the \(application.name) client process",
      chineseSubject: "\(application.name) 客户端进程"
    ).isEmpty { return .started(application.name) }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return .failed(
    message(
      "\(application.name) client launch verification failed",
      "\(application.name) 客户端启动后验证失败"))
}

private func plistFlags(path: String) -> Set<String> {
  guard FileManager.default.fileExists(atPath: path) else { return [] }
  let result = run("/usr/bin/stat", ["-f", "%Sf", path], timeout: 2)
  guard result.status == 0 else { return [] }
  return Set(
    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ",").map(String.init))
}

private func clearImmutableFlags(path: String) -> Set<String>? {
  let protected = plistFlags(path: path).intersection(["schg", "uchg"])
  for flag in protected.sorted() {
    let result = run("/usr/bin/chflags", ["no\(flag)", path], timeout: 3)
    if result.status != 0 {
      fputs(
        message(
          "Could not remove \(flag) from \(path): \(result.stderr)\n",
          "无法移除 \(path) 的 \(flag)：\(result.stderr)\n"), stderr)
      return nil
    }
  }
  return plistFlags(path: path).isDisjoint(with: ["schg", "uchg"]) ? protected : nil
}

private func restoreImmutableFlags(_ flags: Set<String>, path: String) -> Bool {
  if flags.isEmpty { return true }
  for flag in flags.sorted() {
    let result = run("/usr/bin/chflags", [flag, path], timeout: 3)
    if result.status != 0 {
      fputs(
        message(
          "Could not restore \(flag) on \(path): \(result.stderr)\n",
          "无法恢复 \(path) 的 \(flag)：\(result.stderr)\n"), stderr)
      return false
    }
  }
  return flags.isSubset(of: plistFlags(path: path))
}

private func isDisabled(_ job: ManagedJob, uid: uid_t) throws -> Bool {
  let result = run(
    "/bin/launchctl", ["print-disabled", job.domainName(uid: uid)], timeout: 2)
  guard ZeroExitCommandDecision.evaluate(exitStatus: result.status) == .succeeded else {
    throw commandFailure(
      englishSubject: "the policy state of \(job.name)",
      chineseSubject: "\(job.name) 的策略状态", result: result)
  }
  return result.stdout.contains("\"\(job.label)\" => disabled")
}

private func waitForJob(
  _ job: ManagedJob, uid: uid_t, running: Bool, timeout: TimeInterval
) throws -> Bool
{
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    let loaded = try isLoaded(job, uid: uid)
    let pids = try processPIDs(job)
    if running, loaded, !job.expectsResidentProcess || !pids.isEmpty { return true }
    if !running, !loaded, pids.isEmpty { return true }
    Thread.sleep(forTimeInterval: 0.25)
  }
  let loaded = try isLoaded(job, uid: uid)
  let pids = try processPIDs(job)
  return running
    ? loaded && (!job.expectsResidentProcess || !pids.isEmpty) : !loaded && pids.isEmpty
}

private func terminateProcesses(_ job: ManagedJob) throws {
  for pid in try processPIDs(job) { _ = kill(pid, SIGTERM) }
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if try processPIDs(job).isEmpty { return }
    Thread.sleep(forTimeInterval: 0.2)
  }
  for pid in try processPIDs(job) { _ = kill(pid, SIGKILL) }
}

private func auxiliaryProcesses() throws -> (names: [String], pids: [Int32]) {
  var names: [String] = []
  var pids = Set<Int32>()
  for item in auxiliaryProcessPatterns {
    let name = message(item.englishName, item.chineseName)
    let pattern = item.pattern
    let matches = try matchingPIDs(
      pattern, englishSubject: item.englishName, chineseSubject: item.chineseName)
    if !matches.isEmpty { names.append(name) }
    pids.formUnion(matches)
  }
  return (names, pids.sorted())
}

private func terminateAuxiliaryProcesses() throws {
  for pid in try auxiliaryProcesses().pids { _ = kill(pid, SIGTERM) }
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if try auxiliaryProcesses().pids.isEmpty { return }
    Thread.sleep(forTimeInterval: 0.2)
  }
  for pid in try auxiliaryProcesses().pids { _ = kill(pid, SIGKILL) }
}

private func readSnapshot() -> RestoreSnapshot? {
  guard let data = FileManager.default.contents(atPath: snapshotPath) else { return nil }
  return try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
}

private func writeSnapshot(_ snapshot: RestoreSnapshot) -> Bool {
  guard let data = try? JSONEncoder().encode(snapshot) else { return false }
  let directory = (snapshotPath as NSString).deletingLastPathComponent
  do {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
    _ = run("/bin/chmod", ["644", snapshotPath])
    return true
  } catch {
    fputs(
      message(
        "Could not save the recovery snapshot: \(error.localizedDescription)\n",
        "无法保存恢复快照：\(error.localizedDescription)\n"), stderr)
    return false
  }
}

private func addPendingRestore(_ id: String) -> Bool {
  var snapshot = readSnapshot() ?? RestoreSnapshot(createdAt: Date(), pendingJobIDs: [])
  snapshot.pendingJobIDs.insert(id)
  return writeSnapshot(snapshot)
}

private func restoreSavedPlistIfNeeded(_ job: ManagedJob, path: String, uid: uid_t) -> Bool {
  if FileManager.default.fileExists(atPath: path) { return true }
  guard let data = readSnapshot()?.savedPlists?[job.id] else { return false }
  do {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    _ = run("/usr/sbin/chown", [String(uid), path])
    _ = run("/bin/chmod", ["644", path])
    return FileManager.default.fileExists(atPath: path)
  } catch {
    fputs(
      message(
        "Could not restore the plist for \(job.name): \(error.localizedDescription)\n",
        "无法恢复 \(job.name) 的 plist：\(error.localizedDescription)\n"), stderr)
    return false
  }
}

private func removePendingRestore(_ id: String) {
  guard var snapshot = readSnapshot() else { return }
  snapshot.pendingJobIDs.remove(id)
  if snapshot.pendingJobIDs.isEmpty {
    try? FileManager.default.removeItem(atPath: snapshotPath)
  } else {
    _ = writeSnapshot(snapshot)
  }
}

private func activeRelatedSystemExtensions() throws -> [String] {
  let result = run("/usr/bin/systemextensionsctl", ["list"])
  guard ZeroExitCommandDecision.evaluate(exitStatus: result.status) == .succeeded else {
    throw commandFailure(
      englishSubject: "related System Extensions", chineseSubject: "相关 System Extension",
      result: result)
  }
  let identifiers = [
    "com.byteplus.sealsuite.networkextension", "com.volcengine.corplink.systemextension",
  ]
  let activeLines = result.stdout.split(separator: "\n").filter {
    $0.localizedCaseInsensitiveContains("activated enabled")
  }
  return identifiers.filter { identifier in
    activeLines.contains { $0.localizedCaseInsensitiveContains(identifier) }
  }
}

private func findJSONValue(key: String, in value: Any) -> Any? {
  if let dictionary = value as? [String: Any] {
    if let match = dictionary[key] { return match }
    for nested in dictionary.values {
      if let match = findJSONValue(key: key, in: nested) { return match }
    }
  } else if let array = value as? [Any] {
    for nested in array {
      if let match = findJSONValue(key: key, in: nested) { return match }
    }
  }
  return nil
}

private func connectionStatus(_ kind: String) -> String {
  let cliPath = "/usr/local/corplink/corplink-cli"
  guard FileManager.default.isExecutableFile(atPath: cliPath) else { return "unavailable" }
  let result = run(cliPath, ["--format", "json", kind, "status"], timeout: 3)
  guard result.status == 0, let data = result.stdout.data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: data)
  else { return "unavailable" }
  if let status = findJSONValue(key: "connected_status", in: json) as? String {
    return status.lowercased()
  }
  if let status = findJSONValue(key: "status", in: json) as? String { return status.lowercased() }
  if let shouldRoute = findJSONValue(key: "should_route", in: json) as? Bool {
    return shouldRoute ? "connected" : "disconnected"
  }
  return "unknown"
}

private func stopJob(_ job: ManagedJob, uid: uid_t, recordRestore: Bool) throws -> String? {
  let loadedBefore = try isLoaded(job, uid: uid)
  let pidsBefore = try processPIDs(job)
  if !loadedBefore, pidsBefore.isEmpty { return nil }
  if recordRestore, loadedBefore, !addPendingRestore(job.id) {
    return message(
      "\(job.name): could not save recovery state; stop was not performed",
      "\(job.name)：无法保存恢复状态，未执行停止")
  }
  let path = expandedPlistPath(for: job, uid: uid)
  guard let removedFlags = clearImmutableFlags(path: path) else {
    return message(
      "\(job.name): could not temporarily remove immutable plist flags",
      "\(job.name)：无法临时移除 plist 不可变属性")
  }
  var restorationAttempted = false
  defer {
    if !restorationAttempted { _ = restoreImmutableFlags(removedFlags, path: path) }
  }
  var error: String?
  if loadedBefore {
    var result = run("/bin/launchctl", ["bootout", job.target(uid: uid)], timeout: 4)
    if result.status != 0 {
      result = run(
        "/bin/launchctl", ["bootout", job.domainName(uid: uid), path], timeout: 4)
    }
    if result.status != 0 {
      error = message(
        "\(job.name): launchctl bootout failed: \(result.stderr)",
        "\(job.name)：launchctl bootout 失败：\(result.stderr)")
    }
  }
  if error == nil, try !waitForJob(job, uid: uid, running: false, timeout: 3) {
    if try !isLoaded(job, uid: uid), try !processPIDs(job).isEmpty {
      try terminateProcesses(job)
    }
    if try !waitForJob(job, uid: uid, running: false, timeout: 3) {
      error = message(
        "\(job.name): the job or process is still present",
        "\(job.name)：任务或进程仍然存在")
    }
  }
  restorationAttempted = true
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = message(
      "\(job.name): failed to restore the original plist protection flags",
      "\(job.name)：plist 原有保护属性恢复失败")
    error = error.map { "\($0)\(message("; ", "；"))\(flagError)" } ?? flagError
  }
  return error
}

private final class StopErrorCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var errors: [String: String] = [:]

  func record(_ error: String, for id: String) {
    lock.lock()
    errors[id] = error
    lock.unlock()
  }

  func ordered(for ids: [String]) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return ids.compactMap { errors[$0] }
  }
}

private struct JobResidue: Sendable {
  let id: String
  let name: String
  let loaded: Bool
  let pids: [Int32]
}

private final class JobResidueCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var residues: [JobResidue] = []
  private var failures: [String: InspectionFailure] = [:]

  func append(_ residue: JobResidue) {
    lock.lock()
    residues.append(residue)
    lock.unlock()
  }

  func record(_ failure: InspectionFailure, for id: String) {
    lock.lock()
    failures[id] = failure
    lock.unlock()
  }

  func result(for ids: [String]) throws -> [JobResidue] {
    lock.lock()
    defer { lock.unlock() }
    if let failure = ids.compactMap({ failures[$0] }).first { throw failure }
    return residues.sorted { $0.id < $1.id }
  }
}

private func requestJobStop(_ job: ManagedJob, uid: uid_t) throws -> String? {
  let loadedBefore = try isLoaded(job, uid: uid)
  if !loadedBefore, try processPIDs(job).isEmpty { return nil }
  let path = expandedPlistPath(for: job, uid: uid)
  guard let removedFlags = clearImmutableFlags(path: path) else {
    return message(
      "\(job.name): could not temporarily remove immutable plist flags",
      "\(job.name)：无法临时移除 plist 不可变属性")
  }
  var restorationAttempted = false
  defer {
    if !restorationAttempted { _ = restoreImmutableFlags(removedFlags, path: path) }
  }

  var error: String?
  if loadedBefore {
    var result = run(
      "/bin/launchctl", ["bootout", job.target(uid: uid)], timeout: 4)
    if result.status != 0 {
      result = run(
        "/bin/launchctl", ["bootout", job.domainName(uid: uid), path], timeout: 4)
    }
    if result.status != 0, try isLoaded(job, uid: uid) {
      error = message(
        "\(job.name): launchctl bootout failed: \(result.stderr)",
        "\(job.name)：launchctl bootout 失败：\(result.stderr)")
    }
  }
  restorationAttempted = true
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = message(
      "\(job.name): failed to restore the original plist protection flags",
      "\(job.name)：plist 原有保护属性恢复失败")
    error = error.map { "\($0)\(message("; ", "；"))\(flagError)" } ?? flagError
  }
  return error
}

private func requestStopsConcurrently(_ ids: [String], uid: uid_t) -> [String] {
  let collector = StopErrorCollector()
  let group = DispatchGroup()
  for id in ids {
    guard let job = jobs.first(where: { $0.id == id }) else { continue }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      do {
        if let error = try requestJobStop(job, uid: uid) { collector.record(error, for: id) }
      } catch let error as InspectionFailure {
        collector.record(error.localizedMessage, for: id)
      } catch {
        collector.record(error.localizedDescription, for: id)
      }
    }
  }
  group.wait()
  return collector.ordered(for: ids)
}

private func runtimeResidues(uid: uid_t) throws -> [JobResidue] {
  let collector = JobResidueCollector()
  let group = DispatchGroup()
  for job in jobs {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      do {
        let loaded = try isLoaded(job, uid: uid)
        let pids = try processPIDs(job)
        if loaded || !pids.isEmpty {
          collector.append(JobResidue(id: job.id, name: job.name, loaded: loaded, pids: pids))
        }
      } catch let failure as InspectionFailure {
        collector.record(failure, for: job.id)
      } catch {
        collector.record(
          InspectionFailure(
            english: error.localizedDescription, chinese: error.localizedDescription),
          for: job.id)
      }
    }
  }
  group.wait()
  return try collector.result(for: jobs.map(\.id))
}

private func terminateResidueProcesses(_ residues: [JobResidue]) -> [String] {
  let collector = StopErrorCollector()
  let group = DispatchGroup()
  for residue in residues where !residue.pids.isEmpty {
    guard let job = jobs.first(where: { $0.id == residue.id }) else { continue }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      do {
        try terminateProcesses(job)
      } catch let error as InspectionFailure {
        collector.record(error.localizedMessage, for: residue.id)
      } catch {
        collector.record(error.localizedDescription, for: residue.id)
      }
    }
  }
  group.wait()
  return collector.ordered(for: residues.map(\.id))
}

private func convergeStoppedSuite(uid: uid_t) throws -> [String] {
  var retryCount = 0
  var stableSince: Date?
  let deadline = Date().addingTimeInterval(15)

  while Date() < deadline {
    let residues = try runtimeResidues(uid: uid)
    let auxiliary = try auxiliaryProcesses()
    let decision = StopConvergenceDecision.evaluate(
      loadedJobCount: residues.filter(\.loaded).count,
      processCount: residues.reduce(0) { $0 + $1.pids.count } + auxiliary.pids.count,
      retriesPerformed: retryCount)

    switch decision {
    case .converged:
      if stableSince == nil { stableSince = Date() }
      if let stableSince, Date().timeIntervalSince(stableSince) >= 5 { return [] }
    case .retry:
      stableSince = nil
      let retryErrors = requestStopsConcurrently(residues.map(\.id), uid: uid)
      let terminationErrors = terminateResidueProcesses(residues)
      try terminateAuxiliaryProcesses()
      retryCount += 1
      if !retryErrors.isEmpty || !terminationErrors.isEmpty {
        return retryErrors + terminationErrors
      }
    case .failed:
      let names = residues.map(\.name)
      var errors: [String] = []
      if !names.isEmpty {
        errors.append(
          message(
            "Jobs or processes remain: \(names.joined(separator: ", "))",
            "仍有任务或进程：\(names.joined(separator: "、"))"))
      }
      if !auxiliary.pids.isEmpty {
        errors.append(
          message(
            "Auxiliary processes remain: \(auxiliary.names.joined(separator: ", "))",
            "仍有辅助进程：\(auxiliary.names.joined(separator: "、"))"))
      }
      return errors
    }
    Thread.sleep(forTimeInterval: 0.5)
  }

  let residues = try runtimeResidues(uid: uid)
  let auxiliary = try auxiliaryProcesses()
  var errors: [String] = []
  if !residues.isEmpty {
    errors.append(
      message(
        "Stop verification timed out; jobs or processes remain: \(residues.map(\.name).joined(separator: ", "))",
        "停止验证超时，仍有任务或进程：\(residues.map(\.name).joined(separator: "、"))"))
  }
  if !auxiliary.pids.isEmpty {
    errors.append(
      message(
        "Stop verification timed out; auxiliary processes remain: \(auxiliary.names.joined(separator: ", "))",
        "停止验证超时，仍有辅助进程：\(auxiliary.names.joined(separator: "、"))"))
  }
  if errors.isEmpty {
    errors.append(
      message(
        "Stop verification did not reach a five-second stable state.",
        "停止验证未达到连续 5 秒稳定状态。"))
  }
  return errors
}

private func startJob(_ job: ManagedJob, uid: uid_t) throws -> String? {
  let path = expandedPlistPath(for: job, uid: uid)
  if try waitForJob(job, uid: uid, running: true, timeout: 0.1) {
    if !restoreSavedPlistIfNeeded(job, path: path, uid: uid) {
      return message(
        "\(job.name): the job is running, but its saved plist could not be restored",
        "\(job.name)：任务已运行，但停止前的 plist 无法恢复")
    }
    removePendingRestore(job.id)
    return nil
  }
  if try isDisabled(job, uid: uid) {
    return message(
      "\(job.name): disabled by system or organization policy; no override was attempted",
      "\(job.name)：已被系统或组织策略禁用，未擅自修改")
  }
  guard restoreSavedPlistIfNeeded(job, path: path, uid: uid) else {
    return message(
      "\(job.name): plist not found and no saved copy is available",
      "\(job.name)：找不到 plist，且没有可用的停止前备份")
  }
  guard let removedFlags = clearImmutableFlags(path: path) else {
    return message(
      "\(job.name): could not temporarily remove immutable plist flags",
      "\(job.name)：无法临时移除 plist 不可变属性")
  }
  var restorationAttempted = false
  defer {
    if !restorationAttempted { _ = restoreImmutableFlags(removedFlags, path: path) }
  }
  var result = run("/bin/launchctl", ["bootstrap", job.domainName(uid: uid), path])
  if result.status != 0, try isLoaded(job, uid: uid) {
    result = run("/bin/launchctl", ["kickstart", "-k", job.target(uid: uid)])
  }
  var error: String?
  if result.status != 0 {
    error = message(
      "\(job.name): failed to start: \(result.stderr)",
      "\(job.name)：启动失败：\(result.stderr)")
  } else if try !waitForJob(job, uid: uid, running: true, timeout: 8) {
    error = message(
      "\(job.name): post-start verification failed", "\(job.name)：启动后验证失败")
  } else {
    if job.id == "client" { Thread.sleep(forTimeInterval: 2) }
    if restoreSavedPlistIfNeeded(job, path: path, uid: uid) {
      removePendingRestore(job.id)
    } else {
      error = message(
        "\(job.name): started, but its saved plist could not be restored",
        "\(job.name)：已启动，但停止前的 plist 无法恢复")
    }
  }
  restorationAttempted = true
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = message(
      "\(job.name): failed to restore the original plist protection flags",
      "\(job.name)：plist 原有保护属性恢复失败")
    error = error.map { "\($0)\(message("; ", "；"))\(flagError)" } ?? flagError
  }
  return error
}

private func requireRoot(_ action: String) -> Bool {
  guard geteuid() == 0 else {
    fputs(
      message("Administrator privileges are required to \(action).\n", "\(action)需要管理员权限。\n"),
      stderr)
    return false
  }
  return true
}

private func stopComponent(id: String) throws -> Int32 {
  guard requireRoot(message("stop a component", "停止组件")) else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs(message("Unknown component: \(id)\n", "未知组件：\(id)\n"), stderr)
    return 2
  }
  if let error = try stopJob(job, uid: consoleUID(), recordRestore: true) {
    fputs("\(error)\n", stderr)
    return 1
  }
  let suffix = job.launchOnlyOnce
    ? message("; it will be re-registered from the original plist when started", "；再次启动时将使用原始 plist 重新注册")
    : ""
  print(message("\(job.name) stopped with no job or process remaining\(suffix).", "\(job.name)已停止，无任务或进程残留\(suffix)。"))
  return 0
}

private func startComponent(id: String) throws -> Int32 {
  guard requireRoot(message("start a component", "启动组件")) else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs(message("Unknown component: \(id)\n", "未知组件：\(id)\n"), stderr)
    return 2
  }
  if let error = try startJob(job, uid: consoleUID()) {
    fputs("\(error)\n", stderr)
    return job.launchOnlyOnce ? 4 : 1
  }
  print(message("\(job.name) started and passed verification.", "\(job.name)已启动并通过验证。"))
  return 0
}

private func stopSuite() throws -> Int32 {
  guard requireRoot(message("stop the complete Corplink suite", "停止整套飞连")) else { return 77 }
  let uid = consoleUID()
  var loadedIDs = Set<String>()
  for job in jobs where try isLoaded(job, uid: uid) { loadedIDs.insert(job.id) }
  let pendingIDs = loadedIDs.union(readSnapshot()?.pendingJobIDs ?? [])
  var savedPlists = readSnapshot()?.savedPlists ?? [:]
  if let clientJob = jobs.first(where: { $0.id == "client" }) {
    let clientPath = expandedPlistPath(for: clientJob, uid: uid)
    if let data = FileManager.default.contents(atPath: clientPath) {
      savedPlists[clientJob.id] = data
    }
  }
  if pendingIDs.isEmpty {
    try? FileManager.default.removeItem(atPath: snapshotPath)
  } else {
    guard
      writeSnapshot(
        RestoreSnapshot(createdAt: Date(), pendingJobIDs: pendingIDs, savedPlists: savedPlists)
      )
    else {
      return 1
    }
  }

  var errors: [String] = []
  errors.append(
    contentsOf: requestStopsConcurrently(
      ["client", "network-agent", "app-blocker"], uid: uid))
  errors.append(
    contentsOf: requestStopsConcurrently(
      ["data-forwarder", "mdm", "connection", "network-monitor", "protection"],
      uid: uid))
  try terminateAuxiliaryProcesses()
  errors.append(contentsOf: try convergeStoppedSuite(uid: uid))
  let extensions = try activeRelatedSystemExtensions()
  guard errors.isEmpty else {
    fputs(errors.joined(separator: "\n") + "\n", stderr)
    return 1
  }
  let monitorNote = pendingIDs.contains("network-monitor")
    ? message("; Network Monitor will be re-registered on the next start", "；再次开始时会重新注册网络监控")
    : ""
  print(
    message(
      "The complete Corplink suite has stopped. No known job or process returned during the five-second observation\(monitorNote).",
      "整套飞连运行组件已停止；持续观察 5 秒未复活，无已知任务或进程残留\(monitorNote)。"))
  if !extensions.isEmpty {
    print(
      message(
        "Warning: System Extensions remain enabled: \(extensions.joined(separator: ", ")). They were not uninstalled so the stop remains reversible.",
        "提示：System Extension 仍处于启用状态：\(extensions.joined(separator: ", "))。为保持停止操作可恢复，未执行卸载。"))
  }
  return 0
}

private func startSuite() throws -> Int32 {
  guard requireRoot(message("start the complete Corplink suite", "启动整套飞连")) else { return 77 }
  let uid = consoleUID()
  let startOrder = [
    "protection", "network-monitor", "connection", "mdm", "data-forwarder",
    "network-agent", "app-blocker", "client",
  ]
  var errors: [String] = []
  var skipped: [String] = []
  var notes: [String] = []
  let snapshot = readSnapshot()
  var clientLaunchJobInstalled = false
  for id in startOrder {
    guard let job = jobs.first(where: { $0.id == id }) else { continue }
    let path = expandedPlistPath(for: job, uid: uid)
    let facts = ComponentFacts(
      plistPresent: FileManager.default.fileExists(atPath: path),
      loaded: try isLoaded(job, uid: uid),
      processCount: try processPIDs(job).count,
      pendingRestore: snapshot?.pendingJobIDs.contains(job.id) == true)
    let installed = job.id == "client" ? facts.hasLaunchJobEvidence : facts.isInstalled
    if job.id == "client" { clientLaunchJobInstalled = installed }
    guard installed else {
      skipped.append(message("\(job.name) (not installed)", "\(job.name)（未安装）"))
      continue
    }
    if try isDisabled(job, uid: uid) {
      skipped.append(message("\(job.name) (disabled by policy)", "\(job.name)（策略禁用）"))
      continue
    }
    if let error = try startJob(job, uid: uid) { errors.append(error) }
  }
  if !clientLaunchJobInstalled {
    switch try startClientApplicationIfAvailable(uid: uid) {
    case .notInstalled, .alreadyRunning:
      break
    case .started(let name):
      notes.append(
        message(
          "\(name) client was launched without a legacy LaunchAgent",
          "已启动 \(name) 客户端；此安装未使用旧版 LaunchAgent"))
    case .failed(let error):
      errors.append(error)
    }
  }
  guard errors.isEmpty else {
    fputs(errors.joined(separator: "\n") + "\n", stderr)
    return 1
  }
  let skippedNote = skipped.isEmpty
    ? ""
    : message("; not started: \(skipped.joined(separator: ", "))", "；未启动：\(skipped.joined(separator: "、"))")
  print(
    message(
      "All installed Corplink components not disabled by policy started and passed verification\(skippedNote).",
      "所有已安装且未被策略禁用的飞连组件均已启动并通过验证\(skippedNote)。"))
  for note in notes { print(note) }
  return 0
}

private func restoreSuite() throws -> Int32 {
  guard requireRoot(message("restore the Corplink suite", "恢复整套飞连")) else { return 77 }
  guard let snapshot = readSnapshot(), !snapshot.pendingJobIDs.isEmpty else {
    fputs(
      message(
        "There is no saved pre-stop state to restore. Start components individually or restart the Mac.\n",
        "没有待恢复的停止前状态。请在组件页逐项启动，或重启 Mac。\n"), stderr)
    return 2
  }
  let uid = consoleUID()
  let startOrder = [
    "protection", "network-monitor", "connection", "mdm", "data-forwarder",
    "network-agent", "app-blocker", "client",
  ]
  var errors: [String] = []
  for id in startOrder where snapshot.pendingJobIDs.contains(id) {
    guard let job = jobs.first(where: { $0.id == id }) else { continue }
    if let error = try startJob(job, uid: uid) { errors.append(error) }
  }
  guard errors.isEmpty else {
    fputs(errors.joined(separator: "\n") + "\n", stderr)
    return 1
  }
  print(
    message(
      "The Corplink components that were running before the stop have been restored and verified.",
      "已经恢复停止前运行的飞连组件，并逐项通过启动验证。"))
  return 0
}

private func printStatus() throws -> Int32 {
  let uid = consoleUID()
  let snapshot = readSnapshot()
  let extensions = try activeRelatedSystemExtensions()
  let auxiliary = try auxiliaryProcesses()
  var loadedCount = 0
  var installedCount = 0
  var processCount = 0
  var inconsistent = false
  var connectionRuntimeAvailable = false
  for job in jobs {
    let loaded = try isLoaded(job, uid: uid)
    let pids = try processPIDs(job)
    let path = expandedPlistPath(for: job, uid: uid)
    let flags = plistFlags(path: path).filter { $0 != "-" }.sorted()
    let disabled = try isDisabled(job, uid: uid)
    let pending = snapshot?.pendingJobIDs.contains(job.id) == true
    let restartRequired = job.launchOnlyOnce && pending && !loaded
    let facts = ComponentFacts(
      plistPresent: FileManager.default.fileExists(atPath: path), loaded: loaded,
      processCount: pids.count, pendingRestore: pending
    )
    let present = job.id == "client" ? facts.hasLaunchJobEvidence : facts.isInstalled
    if loaded { loadedCount += 1 }
    if present { installedCount += 1 }
    processCount += pids.count
    if job.id == "connection" { connectionRuntimeAvailable = loaded || !pids.isEmpty }
    if loaded != (!pids.isEmpty), job.expectsResidentProcess { inconsistent = true }
    let fields = [
      loaded ? "1" : "0", pids.map(String.init).joined(separator: ":"),
      flags.joined(separator: ":"), disabled ? "1" : "0", restartRequired ? "1" : "0",
      present ? "1" : "0",
    ]
    print("job.\(job.id)=\(fields.joined(separator: "|"))")
  }
  processCount += auxiliary.pids.count
  let runtimeState = SuiteRuntimeState.classify(
    loadedJobs: loadedCount, processCount: processCount,
    activeSystemExtensions: extensions.count)
  let clean = runtimeState == .cleanlyStopped
  print("suite_clean=\(clean ? "true" : "false")")
  print("suite_runtime_stopped=\(runtimeState.runtimeStopped ? "true" : "false")")
  print("suite_loaded=\(loadedCount)")
  print("suite_total=\(installedCount)")
  print("suite_known_total=\(jobs.count)")
  print("suite_processes=\(processCount)")
  print("restore_pending=\(snapshot?.pendingJobIDs.sorted().joined(separator: ",") ?? "")")
  print("auxiliary_components=\(auxiliary.names.joined(separator: ","))")
  print("auxiliary_pids=\(auxiliary.pids.map(String.init).joined(separator: ","))")
  print("vpn=\(connectionRuntimeAvailable ? connectionStatus("vpn") : "unavailable")")
  print("swg=\(connectionRuntimeAvailable ? connectionStatus("swg") : "unavailable")")
  print("system_extensions=\(extensions.joined(separator: ","))")
  print("client_app_present=\(installedClientApplication() == nil ? "false" : "true")")
  print("client_app_running=\(try clientApplicationPIDs().isEmpty ? "false" : "true")")
  if clean { return 3 }
  if inconsistent { return 1 }
  return 0
}

private func printHelp() {
  let componentList = jobs.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
  if usesChinese {
    print(
      """
      用法：corplink-root-helper <命令>

      状态命令：
        status                         输出整套及各组件实时状态（无需管理员权限）

      整套控制：
        stop-suite                     保存运行快照并停止全部已知运行组件
        start-suite                    启动全部已安装且未被策略禁用的组件
        restore-suite                  恢复 stop-suite 前运行的组件

      单项控制：
        stop-component:<id>            停止一个组件并记录恢复状态
        start-component:<id>           启动一个组件

      兼容命令：
        start / stop                   启动或停止 connection 连接主服务

      组件 id：
        \(componentList)

      注意：network-monitor 使用 LaunchOnlyOnce；重新启动时会用原始 plist 创建新的 launchd 任务实例。
      """)
  } else {
    print(
      """
      Usage: corplink-root-helper <command>

      Status:
        status                         Print live suite and component status (no admin privileges required)

      Suite control:
        stop-suite                     Save recovery state and stop all known running components
        start-suite                    Start every installed component not disabled by policy
        restore-suite                  Restore components that were running before stop-suite

      Component control:
        stop-component:<id>            Stop one component and record recovery state
        start-component:<id>           Start one component

      Compatibility commands:
        start / stop                   Start or stop the connection service

      Component IDs:
        \(componentList)

      Note: network-monitor uses LaunchOnlyOnce. Starting it registers a new launchd job from the original plist.
      """)
  }
}

private func executeCommandThrowing(_ command: String) throws -> Int32 {
  switch command {
  case "help", "--help", "-h":
    printHelp()
    return 0
  case "status": return try printStatus()
  case "start": return try startComponent(id: "connection")
  case "stop": return try stopComponent(id: "connection")
  case "stop-suite": return try stopSuite()
  case "start-suite": return try startSuite()
  case "restore-suite": return try restoreSuite()
  default:
    break
  }
  if command.hasPrefix("stop-component:") {
    return try stopComponent(id: String(command.dropFirst("stop-component:".count)))
  }
  if command.hasPrefix("start-component:") {
    return try startComponent(id: String(command.dropFirst("start-component:".count)))
  }
  fputs(message("Unknown command: \(command)\n", "未知命令：\(command)\n"), stderr)
  printHelp()
  return 2
}

private func executeCommand(_ command: String) -> Int32 {
  do {
    return try executeCommandThrowing(command)
  } catch let failure as InspectionFailure {
    fputs("\(failure.localizedMessage)\n", stderr)
    return HelperInspectionFailurePolicy.exitStatus(for: command)
  } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    return HelperInspectionFailurePolicy.exitStatus(for: command)
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--daemon"] { runPrivilegedDaemon() }
guard arguments.count == 1 else {
  printHelp()
  exit(arguments.isEmpty ? 0 : 2)
}
exit(executeCommand(arguments[0]))
