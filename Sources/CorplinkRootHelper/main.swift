import CorplinkControlCore
import Darwin
import Foundation

private let usesChinese =
  ProcessInfo.processInfo.environment["CORPLINK_CONTROL_LANG"] == "zh-Hans"

private func message(_ english: String, _ chinese: String) -> String {
  usesChinese ? chinese : english
}

private enum JobDomain { case system, gui }

private struct ManagedJob {
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

@discardableResult
private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
  let process = Process()
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
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
    stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
    stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func consoleUID() -> uid_t {
  let result = run("/usr/bin/stat", ["-f", "%u", "/dev/console"])
  return uid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? getuid()
}

private func username(for uid: uid_t) -> String? {
  let users = run("/usr/bin/dscl", [".", "-search", "/Users", "UniqueID", String(uid)])
  return users.stdout.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
}

private func expandedPlistPath(for job: ManagedJob, uid: uid_t) -> String {
  guard job.plistPath.hasPrefix("~/") else { return job.plistPath }
  guard let username = username(for: uid) else {
    return job.plistPath
  }
  let homeResult = run("/usr/bin/dscl", [".", "-read", "/Users/\(username)", "NFSHomeDirectory"])
  guard let home = homeResult.stdout.split(whereSeparator: { $0.isWhitespace }).last else {
    return job.plistPath
  }
  return String(home) + String(job.plistPath.dropFirst())
}

private func isLoaded(_ job: ManagedJob, uid: uid_t) -> Bool {
  run("/bin/launchctl", ["print", job.target(uid: uid)]).status == 0
}

private func processPIDs(_ job: ManagedJob) -> [Int32] {
  matchingPIDs(job.processPattern)
}

private func matchingPIDs(_ pattern: String) -> [Int32] {
  let result = run("/usr/bin/pgrep", ["-f", pattern])
  guard result.status == 0 else { return [] }
  return result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }.sorted()
}

private func clientApplicationPIDs() -> [Int32] {
  Array(Set(clientApplications.flatMap { matchingPIDs($0.processPattern) })).sorted()
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

private func startClientApplicationIfAvailable(uid: uid_t) -> ClientApplicationStartResult {
  if !clientApplicationPIDs().isEmpty { return .alreadyRunning }
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
    if !matchingPIDs(application.processPattern).isEmpty { return .started(application.name) }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return .failed(
    message(
      "\(application.name) client launch verification failed",
      "\(application.name) 客户端启动后验证失败"))
}

private func plistFlags(path: String) -> Set<String> {
  guard FileManager.default.fileExists(atPath: path) else { return [] }
  let result = run("/usr/bin/stat", ["-f", "%Sf", path])
  guard result.status == 0 else { return [] }
  return Set(
    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ",").map(String.init))
}

private func clearImmutableFlags(path: String) -> Set<String>? {
  let protected = plistFlags(path: path).intersection(["schg", "uchg"])
  for flag in protected.sorted() {
    let result = run("/usr/bin/chflags", ["no\(flag)", path])
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
  for flag in flags.sorted() {
    let result = run("/usr/bin/chflags", [flag, path])
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

private func isDisabled(_ job: ManagedJob, uid: uid_t) -> Bool {
  let result = run("/bin/launchctl", ["print-disabled", job.domainName(uid: uid)])
  return result.stdout.contains("\"\(job.label)\" => disabled")
}

private func waitForJob(_ job: ManagedJob, uid: uid_t, running: Bool, timeout: TimeInterval) -> Bool
{
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    let loaded = isLoaded(job, uid: uid)
    let pids = processPIDs(job)
    if running, loaded, !job.expectsResidentProcess || !pids.isEmpty { return true }
    if !running, !loaded, pids.isEmpty { return true }
    Thread.sleep(forTimeInterval: 0.25)
  }
  let loaded = isLoaded(job, uid: uid)
  let pids = processPIDs(job)
  return running
    ? loaded && (!job.expectsResidentProcess || !pids.isEmpty) : !loaded && pids.isEmpty
}

private func terminateProcesses(_ job: ManagedJob) {
  for pid in processPIDs(job) { _ = kill(pid, SIGTERM) }
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if processPIDs(job).isEmpty { return }
    Thread.sleep(forTimeInterval: 0.2)
  }
  for pid in processPIDs(job) { _ = kill(pid, SIGKILL) }
}

private func auxiliaryProcesses() -> (names: [String], pids: [Int32]) {
  var names: [String] = []
  var pids = Set<Int32>()
  for item in auxiliaryProcessPatterns {
    let name = message(item.englishName, item.chineseName)
    let pattern = item.pattern
    let matches = matchingPIDs(pattern)
    if !matches.isEmpty { names.append(name) }
    pids.formUnion(matches)
  }
  return (names, pids.sorted())
}

private func terminateAuxiliaryProcesses() {
  for pid in auxiliaryProcesses().pids { _ = kill(pid, SIGTERM) }
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if auxiliaryProcesses().pids.isEmpty { return }
    Thread.sleep(forTimeInterval: 0.2)
  }
  for pid in auxiliaryProcesses().pids { _ = kill(pid, SIGKILL) }
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

private func activeRelatedSystemExtensions() -> [String] {
  let result = run("/usr/bin/systemextensionsctl", ["list"])
  guard result.status == 0 else { return [] }
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
  let result = run(cliPath, ["--format", "json", kind, "status"])
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

private func stopJob(_ job: ManagedJob, uid: uid_t, recordRestore: Bool) -> String? {
  let loadedBefore = isLoaded(job, uid: uid)
  let pidsBefore = processPIDs(job)
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
  var error: String?
  if loadedBefore {
    var result = run("/bin/launchctl", ["bootout", job.target(uid: uid)])
    if result.status != 0 {
      result = run("/bin/launchctl", ["bootout", job.domainName(uid: uid), path])
    }
    if result.status != 0 {
      error = message(
        "\(job.name): launchctl bootout failed: \(result.stderr)",
        "\(job.name)：launchctl bootout 失败：\(result.stderr)")
    }
  }
  if error == nil, !waitForJob(job, uid: uid, running: false, timeout: 3) {
    if !isLoaded(job, uid: uid), !processPIDs(job).isEmpty { terminateProcesses(job) }
    if !waitForJob(job, uid: uid, running: false, timeout: 3) {
      error = message(
        "\(job.name): the job or process is still present",
        "\(job.name)：任务或进程仍然存在")
    }
  }
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = message(
      "\(job.name): failed to restore the original plist protection flags",
      "\(job.name)：plist 原有保护属性恢复失败")
    error = error.map { "\($0)\(message("; ", "；"))\(flagError)" } ?? flagError
  }
  return error
}

private func startJob(_ job: ManagedJob, uid: uid_t) -> String? {
  let path = expandedPlistPath(for: job, uid: uid)
  if waitForJob(job, uid: uid, running: true, timeout: 0.1) {
    if !restoreSavedPlistIfNeeded(job, path: path, uid: uid) {
      return message(
        "\(job.name): the job is running, but its saved plist could not be restored",
        "\(job.name)：任务已运行，但停止前的 plist 无法恢复")
    }
    removePendingRestore(job.id)
    return nil
  }
  if isDisabled(job, uid: uid) {
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
  var result = run("/bin/launchctl", ["bootstrap", job.domainName(uid: uid), path])
  if result.status != 0, isLoaded(job, uid: uid) {
    result = run("/bin/launchctl", ["kickstart", "-k", job.target(uid: uid)])
  }
  var error: String?
  if result.status != 0 {
    error = message(
      "\(job.name): failed to start: \(result.stderr)",
      "\(job.name)：启动失败：\(result.stderr)")
  } else if !waitForJob(job, uid: uid, running: true, timeout: 8) {
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

private func stopComponent(id: String) -> Int32 {
  guard requireRoot(message("stop a component", "停止组件")) else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs(message("Unknown component: \(id)\n", "未知组件：\(id)\n"), stderr)
    return 2
  }
  if let error = stopJob(job, uid: consoleUID(), recordRestore: true) {
    fputs("\(error)\n", stderr)
    return 1
  }
  let suffix = job.launchOnlyOnce
    ? message("; it will be re-registered from the original plist when started", "；再次启动时将使用原始 plist 重新注册")
    : ""
  print(message("\(job.name) stopped with no job or process remaining\(suffix).", "\(job.name)已停止，无任务或进程残留\(suffix)。"))
  return 0
}

private func startComponent(id: String) -> Int32 {
  guard requireRoot(message("start a component", "启动组件")) else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs(message("Unknown component: \(id)\n", "未知组件：\(id)\n"), stderr)
    return 2
  }
  if let error = startJob(job, uid: consoleUID()) {
    fputs("\(error)\n", stderr)
    return job.launchOnlyOnce ? 4 : 1
  }
  print(message("\(job.name) started and passed verification.", "\(job.name)已启动并通过验证。"))
  return 0
}

private func stopSuite() -> Int32 {
  guard requireRoot(message("stop the complete Corplink suite", "停止整套飞连")) else { return 77 }
  let uid = consoleUID()
  let loadedIDs = Set(jobs.filter { isLoaded($0, uid: uid) }.map(\.id))
  let pendingIDs = loadedIDs.union(readSnapshot()?.pendingJobIDs ?? [])
  var savedPlists = readSnapshot()?.savedPlists ?? [:]
  if let clientJob = jobs.first(where: { $0.id == "client" }) {
    let clientPath = expandedPlistPath(for: clientJob, uid: uid)
    if let data = FileManager.default.contents(atPath: clientPath) {
      savedPlists[clientJob.id] = data
    }
  }
  guard
    writeSnapshot(
      RestoreSnapshot(createdAt: Date(), pendingJobIDs: pendingIDs, savedPlists: savedPlists)
    )
  else {
    return 1
  }
  let stopOrder = [
    "client", "network-agent", "app-blocker", "data-forwarder", "mdm",
    "connection", "network-monitor", "protection",
  ]
  var errors: [String] = []
  for id in stopOrder {
    guard let job = jobs.first(where: { $0.id == id }) else { continue }
    if let error = stopJob(job, uid: uid, recordRestore: false) { errors.append(error) }
  }
  terminateAuxiliaryProcesses()
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.5)
  }
  let residues = jobs.filter { isLoaded($0, uid: uid) || !processPIDs($0).isEmpty }.map(\.name)
  if !residues.isEmpty {
    errors.append(
      message(
        "Jobs or processes remain: \(residues.joined(separator: ", "))",
        "仍有任务或进程：\(residues.joined(separator: "、"))"))
  }
  let auxiliaryResidues = auxiliaryProcesses()
  if !auxiliaryResidues.pids.isEmpty {
    errors.append(
      message(
        "Auxiliary processes remain: \(auxiliaryResidues.names.joined(separator: ", "))",
        "仍有辅助进程：\(auxiliaryResidues.names.joined(separator: "、"))"))
  }
  let extensions = activeRelatedSystemExtensions()
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

private func startSuite() -> Int32 {
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
      loaded: isLoaded(job, uid: uid),
      processCount: processPIDs(job).count,
      pendingRestore: snapshot?.pendingJobIDs.contains(job.id) == true)
    let installed = job.id == "client" ? facts.hasLaunchJobEvidence : facts.isInstalled
    if job.id == "client" { clientLaunchJobInstalled = installed }
    guard installed else {
      skipped.append(message("\(job.name) (not installed)", "\(job.name)（未安装）"))
      continue
    }
    if isDisabled(job, uid: uid) {
      skipped.append(message("\(job.name) (disabled by policy)", "\(job.name)（策略禁用）"))
      continue
    }
    if let error = startJob(job, uid: uid) { errors.append(error) }
  }
  if !clientLaunchJobInstalled {
    switch startClientApplicationIfAvailable(uid: uid) {
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

private func restoreSuite() -> Int32 {
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
    if let error = startJob(job, uid: uid) { errors.append(error) }
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

private func printStatus() -> Int32 {
  let uid = consoleUID()
  let snapshot = readSnapshot()
  let extensions = activeRelatedSystemExtensions()
  let auxiliary = auxiliaryProcesses()
  var loadedCount = 0
  var installedCount = 0
  var processCount = 0
  var inconsistent = false
  for job in jobs {
    let loaded = isLoaded(job, uid: uid)
    let pids = processPIDs(job)
    let path = expandedPlistPath(for: job, uid: uid)
    let flags = plistFlags(path: path).filter { $0 != "-" }.sorted()
    let disabled = isDisabled(job, uid: uid)
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
  print("vpn=\(connectionStatus("vpn"))")
  print("swg=\(connectionStatus("swg"))")
  print("system_extensions=\(extensions.joined(separator: ","))")
  print("client_app_present=\(installedClientApplication() == nil ? "false" : "true")")
  print("client_app_running=\(clientApplicationPIDs().isEmpty ? "false" : "true")")
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

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
  printHelp()
  exit(arguments.isEmpty ? 0 : 2)
}
let command = arguments[0]
switch command {
case "help", "--help", "-h":
  printHelp()
  exit(0)
case "status": exit(printStatus())
case "start": exit(startComponent(id: "connection"))
case "stop": exit(stopComponent(id: "connection"))
case "stop-suite": exit(stopSuite())
case "start-suite": exit(startSuite())
case "restore-suite": exit(restoreSuite())
default:
  if command.hasPrefix("stop-component:") {
    exit(stopComponent(id: String(command.dropFirst("stop-component:".count))))
  }
  if command.hasPrefix("start-component:") {
    exit(startComponent(id: String(command.dropFirst("start-component:".count))))
  }
  fputs(message("Unknown command: \(command)\n", "未知命令：\(command)\n"), stderr)
  printHelp()
  exit(2)
}
