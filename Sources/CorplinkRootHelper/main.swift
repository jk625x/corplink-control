import Darwin
import Foundation

private enum JobDomain { case system, gui }

private struct ManagedJob {
  let id: String
  let name: String
  let label: String
  let domain: JobDomain
  let plistPath: String
  let processPattern: String
  let launchOnlyOnce: Bool
  let expectsResidentProcess: Bool

  func domainName(uid: uid_t) -> String {
    domain == .system ? "system" : "gui/\(uid)"
  }

  func target(uid: uid_t) -> String { "\(domainName(uid: uid))/\(label)" }
}

private let jobs = [
  ManagedJob(
    id: "connection", name: "连接主服务", label: "com.volcengine.corplink.service",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.volcengine.corplink.service.plist",
    processPattern: "^/usr/local/corplink/corplink-service([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "protection", name: "系统防护", label: "com.volcengine.corplink.systemextension",
    domain: .system,
    plistPath: "/Library/LaunchDaemons/com.volcengine.corplink.systemextension.plist",
    processPattern: "^/Library/CorpLink/", launchOnlyOnce: false,
    expectsResidentProcess: true),
  ManagedJob(
    id: "network-monitor", name: "网络监控", label: "com.corplink.networkmonitor",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.corplink.networkmonitor.plist",
    processPattern: "^/usr/local/corplink/bin/NetworkMonitor([[:space:]]|$)",
    launchOnlyOnce: true, expectsResidentProcess: true),
  ManagedJob(
    id: "data-forwarder", name: "策略数据转发", label: "com.corplink.data_forwarder",
    domain: .system, plistPath: "/Library/LaunchDaemons/com.corplink.data_forwarder.plist",
    processPattern: "^/usr/local/corplink/mdm/.+policy_data_forwarder\\.rb([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: false),
  ManagedJob(
    id: "mdm", name: "MDM 策略", label: "com.corplink.mdm.policy", domain: .system,
    plistPath: "/Library/LaunchDaemons/com.corplink.mdm.policy.plist",
    processPattern: "^/usr/local/corplink/mdm/.+/clpolicy agent([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "network-agent", name: "网络扩展代理", label: "com.volcengine.corplink.agent",
    domain: .gui, plistPath: "/Library/LaunchAgents/com.volcengine.corplink.agent.plist",
    processPattern:
      "^/Applications/CorpLink\\.app/Contents/Frameworks/CorplinkNe\\.app/Contents/MacOS/CorplinkNe([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "app-blocker", name: "应用管控", label: "com.corplink.appblocker", domain: .gui,
    plistPath: "/Library/LaunchAgents/com.corplink.appblocker.plist",
    processPattern: "^/usr/local/corplink/bin/appblocker([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: true),
  ManagedJob(
    id: "client", name: "客户端登录项", label: "CorpLink", domain: .gui,
    plistPath: "~/Library/LaunchAgents/CorpLink.plist",
    processPattern: "^/Applications/CorpLink\\.app/Contents/MacOS/CorpLink([[:space:]]|$)",
    launchOnlyOnce: false, expectsResidentProcess: false),
]

private let snapshotPath = "/Library/Application Support/CorplinkControl/restore-state.json"
private let auxiliaryProcessPatterns = [
  (
    "Finder Sync",
    "^/Applications/(CorpLink|SealSuite)\\.app/.+/CorpLink Finder Sync([[:space:]]|$)"
  ),
  ("SealSuite 客户端", "^/Applications/SealSuite\\.app/Contents/MacOS/SealSuite([[:space:]]|$)"),
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

private func expandedPlistPath(for job: ManagedJob, uid: uid_t) -> String {
  guard job.plistPath.hasPrefix("~/") else { return job.plistPath }
  let users = run("/usr/bin/dscl", [".", "-search", "/Users", "UniqueID", String(uid)])
  guard let username = users.stdout.split(whereSeparator: { $0.isWhitespace }).first else {
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
  let result = run("/usr/bin/pgrep", ["-f", job.processPattern])
  guard result.status == 0 else { return [] }
  return result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }.sorted()
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
      fputs("无法移除 \(path) 的 \(flag)：\(result.stderr)\n", stderr)
      return nil
    }
  }
  return plistFlags(path: path).isDisjoint(with: ["schg", "uchg"]) ? protected : nil
}

private func restoreImmutableFlags(_ flags: Set<String>, path: String) -> Bool {
  for flag in flags.sorted() {
    let result = run("/usr/bin/chflags", [flag, path])
    if result.status != 0 {
      fputs("无法恢复 \(path) 的 \(flag)：\(result.stderr)\n", stderr)
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
  for (name, pattern) in auxiliaryProcessPatterns {
    let result = run("/usr/bin/pgrep", ["-f", pattern])
    guard result.status == 0 else { continue }
    let matches = result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
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
    fputs("无法保存恢复快照：\(error.localizedDescription)\n", stderr)
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
    fputs("无法恢复 \(job.name) 的 plist：\(error.localizedDescription)\n", stderr)
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
    return "\(job.name)：无法保存恢复状态，未执行停止"
  }
  let path = expandedPlistPath(for: job, uid: uid)
  guard let removedFlags = clearImmutableFlags(path: path) else {
    return "\(job.name)：无法临时移除 plist 不可变属性"
  }
  var error: String?
  if loadedBefore {
    var result = run("/bin/launchctl", ["bootout", job.target(uid: uid)])
    if result.status != 0 {
      result = run("/bin/launchctl", ["bootout", job.domainName(uid: uid), path])
    }
    if result.status != 0 { error = "\(job.name)：launchctl bootout 失败：\(result.stderr)" }
  }
  if error == nil, !waitForJob(job, uid: uid, running: false, timeout: 3) {
    if !isLoaded(job, uid: uid), !processPIDs(job).isEmpty { terminateProcesses(job) }
    if !waitForJob(job, uid: uid, running: false, timeout: 3) {
      error = "\(job.name)：任务或进程仍然存在"
    }
  }
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = "\(job.name)：plist 原有保护属性恢复失败"
    error = error.map { "\($0)；\(flagError)" } ?? flagError
  }
  return error
}

private func startJob(_ job: ManagedJob, uid: uid_t) -> String? {
  let path = expandedPlistPath(for: job, uid: uid)
  if waitForJob(job, uid: uid, running: true, timeout: 0.1) {
    if !restoreSavedPlistIfNeeded(job, path: path, uid: uid) {
      return "\(job.name)：任务已运行，但停止前的 plist 无法恢复"
    }
    removePendingRestore(job.id)
    return nil
  }
  if job.launchOnlyOnce, readSnapshot()?.pendingJobIDs.contains(job.id) == true {
    return "\(job.name)：LaunchOnlyOnce 任务停止后必须重启 Mac 才能可靠恢复"
  }
  if isDisabled(job, uid: uid) { return "\(job.name)：已被系统或组织策略禁用，未擅自修改" }
  guard restoreSavedPlistIfNeeded(job, path: path, uid: uid) else {
    return "\(job.name)：找不到 plist，且没有可用的停止前备份"
  }
  guard let removedFlags = clearImmutableFlags(path: path) else {
    return "\(job.name)：无法临时移除 plist 不可变属性"
  }
  var result = run("/bin/launchctl", ["bootstrap", job.domainName(uid: uid), path])
  if result.status != 0, isLoaded(job, uid: uid) {
    result = run("/bin/launchctl", ["kickstart", "-k", job.target(uid: uid)])
  }
  var error: String?
  if result.status != 0 {
    error = "\(job.name)：启动失败：\(result.stderr)"
  } else if !waitForJob(job, uid: uid, running: true, timeout: 8) {
    error = "\(job.name)：启动后验证失败"
  } else {
    if job.id == "client" { Thread.sleep(forTimeInterval: 2) }
    if restoreSavedPlistIfNeeded(job, path: path, uid: uid) {
      removePendingRestore(job.id)
    } else {
      error = "\(job.name)：已启动，但停止前的 plist 无法恢复"
    }
  }
  if !restoreImmutableFlags(removedFlags, path: path) {
    let flagError = "\(job.name)：plist 原有保护属性恢复失败"
    error = error.map { "\($0)；\(flagError)" } ?? flagError
  }
  return error
}

private func requireRoot(_ action: String) -> Bool {
  guard geteuid() == 0 else {
    fputs("\(action)需要管理员权限。\n", stderr)
    return false
  }
  return true
}

private func stopComponent(id: String) -> Int32 {
  guard requireRoot("停止组件") else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs("未知组件：\(id)\n", stderr)
    return 2
  }
  if let error = stopJob(job, uid: consoleUID(), recordRestore: true) {
    fputs("\(error)\n", stderr)
    return 1
  }
  let suffix = job.launchOnlyOnce ? "；再次启动需要重启 Mac" : ""
  print("\(job.name)已停止，无任务或进程残留\(suffix)。")
  return 0
}

private func startComponent(id: String) -> Int32 {
  guard requireRoot("启动组件") else { return 77 }
  guard let job = jobs.first(where: { $0.id == id }) else {
    fputs("未知组件：\(id)\n", stderr)
    return 2
  }
  if let error = startJob(job, uid: consoleUID()) {
    fputs("\(error)\n", stderr)
    return job.launchOnlyOnce ? 4 : 1
  }
  print("\(job.name)已启动并通过验证。")
  return 0
}

private func stopSuite() -> Int32 {
  guard requireRoot("停止整套飞连") else { return 77 }
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
  if !residues.isEmpty { errors.append("仍有任务或进程：\(residues.joined(separator: "、"))") }
  let auxiliaryResidues = auxiliaryProcesses()
  if !auxiliaryResidues.pids.isEmpty {
    errors.append("仍有辅助进程：\(auxiliaryResidues.names.joined(separator: "、"))")
  }
  let extensions = activeRelatedSystemExtensions()
  if !extensions.isEmpty {
    errors.append("仍有活跃 System Extension：\(extensions.joined(separator: ", "))；为保持可恢复性未执行卸载")
  }
  guard errors.isEmpty else {
    fputs(errors.joined(separator: "\n") + "\n", stderr)
    return 1
  }
  let rebootNote = pendingIDs.contains("network-monitor") ? "；网络监控恢复需要重启 Mac" : ""
  print("整套飞连运行组件已停止；持续观察 5 秒未复活，无已知任务或进程残留\(rebootNote)。")
  return 0
}

private func restoreSuite() -> Int32 {
  guard requireRoot("恢复整套飞连") else { return 77 }
  guard let snapshot = readSnapshot(), !snapshot.pendingJobIDs.isEmpty else {
    fputs("没有待恢复的停止前状态。请在组件页逐项启动，或重启 Mac。\n", stderr)
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
    return errors.contains(where: { $0.contains("LaunchOnlyOnce") }) ? 4 : 1
  }
  print("已经恢复停止前运行的飞连组件，并逐项通过启动验证。")
  return 0
}

private func printStatus() -> Int32 {
  let uid = consoleUID()
  let snapshot = readSnapshot()
  let extensions = activeRelatedSystemExtensions()
  let auxiliary = auxiliaryProcesses()
  var loadedCount = 0
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
    if loaded { loadedCount += 1 }
    processCount += pids.count
    if loaded != (!pids.isEmpty), job.expectsResidentProcess { inconsistent = true }
    let fields = [
      loaded ? "1" : "0", pids.map(String.init).joined(separator: ":"),
      flags.joined(separator: ":"), disabled ? "1" : "0", restartRequired ? "1" : "0",
      FileManager.default.fileExists(atPath: path) ? "1" : "0",
    ]
    print("job.\(job.id)=\(fields.joined(separator: "|"))")
  }
  processCount += auxiliary.pids.count
  let clean = loadedCount == 0 && processCount == 0 && extensions.isEmpty
  print("suite_clean=\(clean ? "true" : "false")")
  print("suite_loaded=\(loadedCount)")
  print("suite_total=\(jobs.count)")
  print("suite_processes=\(processCount)")
  print("restore_pending=\(snapshot?.pendingJobIDs.sorted().joined(separator: ",") ?? "")")
  print("auxiliary_components=\(auxiliary.names.joined(separator: ","))")
  print("auxiliary_pids=\(auxiliary.pids.map(String.init).joined(separator: ","))")
  print("vpn=\(connectionStatus("vpn"))")
  print("swg=\(connectionStatus("swg"))")
  print("system_extensions=\(extensions.joined(separator: ","))")
  if clean { return 3 }
  if inconsistent { return 1 }
  return 0
}

private func printHelp() {
  print(
    """
    用法：corplink-root-helper <命令>

    状态命令：
      status                         输出整套及各组件实时状态（无需管理员权限）

    整套控制：
      stop-suite                     保存运行快照并停止全部已知运行组件
      restore-suite                  恢复 stop-suite 前运行的组件

    单项控制：
      stop-component:<id>            停止一个组件并记录恢复状态
      start-component:<id>           启动一个组件

    兼容命令：
      start / stop                   启动或停止 connection 连接主服务

    组件 id：
      \(jobs.map { "\($0.id) (\($0.name))" }.joined(separator: ", "))

    注意：network-monitor 使用 LaunchOnlyOnce，停止后必须重启 Mac 才能可靠恢复。
    """)
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
case "restore-suite": exit(restoreSuite())
default:
  if command.hasPrefix("stop-component:") {
    exit(stopComponent(id: String(command.dropFirst("stop-component:".count))))
  }
  if command.hasPrefix("start-component:") {
    exit(startComponent(id: String(command.dropFirst("start-component:".count))))
  }
  fputs("未知命令：\(command)\n", stderr)
  printHelp()
  exit(2)
}
