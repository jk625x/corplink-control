import Darwin
import Foundation

private let serviceLabel = "com.volcengine.corplink.service"
private let serviceTarget = "system/\(serviceLabel)"
private let plistPath = "/Library/LaunchDaemons/\(serviceLabel).plist"
private let executablePath = "/usr/local/corplink/corplink-service"
private let backgroundJobs = [
  ("system/com.volcengine.corplink.systemextension", "系统防护"),
  ("system/com.corplink.networkmonitor", "网络监控"),
  ("system/com.corplink.data_forwarder", "策略数据转发"),
  ("system/com.corplink.mdm.policy", "MDM 策略"),
  ("gui/%UID%/com.volcengine.corplink.agent", "网络扩展代理"),
  ("gui/%UID%/com.corplink.appblocker", "应用管控"),
  ("gui/%UID%/CorpLink", "客户端登录项"),
]
private let backgroundProcessPatterns = [
  ("^/Library/CorpLink/", "系统防护"),
  ("^/usr/local/corplink/bin/NetworkMonitor([[:space:]]|$)", "网络监控"),
  ("^/usr/local/corplink/bin/appblocker([[:space:]]|$)", "应用管控"),
  ("^/usr/local/corplink/mdm/", "MDM 策略"),
  ("^/Applications/CorpLink.app/Contents/Frameworks/CorplinkNe.app/", "网络扩展代理"),
  ("^/Applications/CorpLink.app/Contents/MacOS/CorpLink([[:space:]]|$)", "客户端界面"),
]

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

  let stdout = String(
    decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  let stderr = String(
    decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func isLoaded() -> Bool {
  run("/bin/launchctl", ["print", serviceTarget]).status == 0
}

private func servicePIDs() -> [Int32] {
  let pattern = "^\(executablePath)([[:space:]]|$)"
  let result = run("/usr/bin/pgrep", ["-f", pattern])
  guard result.status == 0 else { return [] }
  return result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
}

private func plistFlags() -> Set<String> {
  guard FileManager.default.fileExists(atPath: plistPath) else { return [] }
  let result = run("/usr/bin/stat", ["-f", "%Sf", plistPath])
  guard result.status == 0 else { return [] }
  return Set(
    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ",").map(String.init)
  )
}

private func clearImmutableFlags() -> Set<String>? {
  let protected = plistFlags().intersection(["schg", "uchg"])
  for flag in protected.sorted() {
    print("正在移除 plist 属性：\(flag)")
    let result = run("/usr/bin/chflags", ["no\(flag)", plistPath])
    if result.status != 0 {
      fputs("无法移除 \(flag)：\(result.stderr)\n", stderr)
      return nil
    }
  }
  guard plistFlags().isDisjoint(with: ["schg", "uchg"]) else { return nil }
  return protected
}

private func restoreImmutableFlags(_ flags: Set<String>) -> Bool {
  for flag in flags.sorted() {
    let result = run("/usr/bin/chflags", [flag, plistPath])
    if result.status != 0 {
      fputs("无法恢复 \(flag) 属性：\(result.stderr)\n", stderr)
      return false
    }
  }
  return flags.isSubset(of: plistFlags())
}

private func waitForState(running: Bool, timeout: TimeInterval) -> (Bool, [Int32]) {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    let loaded = isLoaded()
    let pids = servicePIDs()
    if running, loaded, !pids.isEmpty { return (loaded, pids) }
    if !running, !loaded, pids.isEmpty { return (loaded, pids) }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return (isLoaded(), servicePIDs())
}

private func verifyStoppedStably(duration: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(duration)
  while Date() < deadline {
    if isLoaded() || !servicePIDs().isEmpty { return false }
    Thread.sleep(forTimeInterval: 0.5)
  }
  return !isLoaded() && servicePIDs().isEmpty
}

private func loadedBackgroundJobs(uid: uid_t) -> [String] {
  backgroundJobs.compactMap { target, name in
    let resolvedTarget = target.replacingOccurrences(of: "%UID%", with: String(uid))
    return run("/bin/launchctl", ["print", resolvedTarget]).status == 0 ? name : nil
  }
}

private func backgroundProcesses() -> (names: [String], pids: [Int32]) {
  var names = Set<String>()
  var pids = Set<Int32>()
  for (pattern, name) in backgroundProcessPatterns {
    let result = run("/usr/bin/pgrep", ["-f", pattern])
    guard result.status == 0 else { continue }
    let matches = result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
    if !matches.isEmpty { names.insert(name) }
    pids.formUnion(matches)
  }
  return (names.sorted(), pids.sorted())
}

private func activeRelatedSystemExtensions() -> [String] {
  let result = run("/usr/bin/systemextensionsctl", ["list"])
  guard result.status == 0 else { return [] }
  let identifiers = [
    "com.byteplus.sealsuite.networkextension",
    "com.volcengine.corplink.systemextension",
  ]
  return identifiers.filter { result.stdout.localizedCaseInsensitiveContains($0) }
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
  if let status = findJSONValue(key: "status", in: json) as? String {
    return status.lowercased()
  }
  if let shouldRoute = findJSONValue(key: "should_route", in: json) as? Bool {
    return shouldRoute ? "connected" : "disconnected"
  }
  return "unknown"
}

private func startService() -> Int32 {
  guard geteuid() == 0 else {
    fputs("启动服务需要管理员权限。\n", stderr)
    return 77
  }
  guard FileManager.default.fileExists(atPath: plistPath) else {
    fputs("找不到服务配置：\(plistPath)\n", stderr)
    return 1
  }

  let result: CommandResult
  if isLoaded() {
    result = run("/bin/launchctl", ["kickstart", "-k", serviceTarget])
  } else {
    _ = run("/bin/launchctl", ["enable", serviceTarget])
    result = run("/bin/launchctl", ["bootstrap", "system", plistPath])
  }
  guard result.status == 0 else {
    fputs("启动命令失败：\(result.stderr)\n", stderr)
    return 1
  }

  let state = waitForState(running: true, timeout: 8)
  guard state.0, !state.1.isEmpty else {
    fputs("启动后验证失败。\n", stderr)
    return 1
  }
  print("服务已启动（PID: \(state.1.map(String.init).joined(separator: ", "))）")
  return 0
}

private func terminateOrphans(_ pids: [Int32]) {
  for pid in pids { _ = kill(pid, SIGTERM) }
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if servicePIDs().isEmpty { return }
    Thread.sleep(forTimeInterval: 0.2)
  }
  for pid in servicePIDs() { _ = kill(pid, SIGKILL) }
}

private func stopService() -> Int32 {
  guard geteuid() == 0 else {
    fputs("停止服务需要管理员权限。\n", stderr)
    return 77
  }

  let loadedBefore = isLoaded()
  let pidsBefore = servicePIDs()
  if !loadedBefore, pidsBefore.isEmpty {
    print("服务已经停止；未修改 plist 属性。")
    return 0
  }
  guard let removedFlags = clearImmutableFlags() else {
    fputs("无法清除 plist 的不可变属性。\n", stderr)
    return 1
  }

  if loadedBefore {
    var result = run("/bin/launchctl", ["bootout", serviceTarget])
    if result.status != 0 {
      result = run("/bin/launchctl", ["bootout", "system", plistPath])
    }
    guard result.status == 0 else {
      _ = restoreImmutableFlags(removedFlags)
      fputs("卸载服务失败：\(result.stderr)\n", stderr)
      return 1
    }
  }

  var state = waitForState(running: false, timeout: 3)
  if !state.0, !state.1.isEmpty {
    terminateOrphans(state.1)
    state = waitForState(running: false, timeout: 3)
  }
  guard !state.0, state.1.isEmpty else {
    _ = restoreImmutableFlags(removedFlags)
    fputs("停止后验证失败。\n", stderr)
    return 1
  }
  guard verifyStoppedStably(duration: 5) else {
    _ = restoreImmutableFlags(removedFlags)
    fputs("连接服务在观察期内重新出现，停止失败。\n", stderr)
    return 1
  }
  guard restoreImmutableFlags(removedFlags) else {
    fputs("连接服务已停止，但 plist 原有保护属性恢复失败。\n", stderr)
    return 1
  }
  print("连接服务已卸载，无残留进程；持续观察 5 秒未复活，plist 保护属性已恢复。")
  return 0
}

private func printStatus() -> Int32 {
  let loaded = isLoaded()
  let pids = servicePIDs()
  let flags = plistFlags().sorted()
  let consoleUID = getuid()
  let jobs = loadedBackgroundJobs(uid: consoleUID)
  let processes = backgroundProcesses()
  let systemExtensions = activeRelatedSystemExtensions()
  print("loaded=\(loaded ? "true" : "false")")
  print("pids=\(pids.map(String.init).joined(separator: ","))")
  print("flags=\(flags.joined(separator: ","))")
  print("vpn=\(connectionStatus("vpn"))")
  print("swg=\(connectionStatus("swg"))")
  print("background_jobs=\(jobs.joined(separator: ","))")
  print("background_components=\(processes.names.joined(separator: ","))")
  print("background_pids=\(processes.pids.map(String.init).joined(separator: ","))")
  print("system_extensions=\(systemExtensions.joined(separator: ","))")
  if loaded, !pids.isEmpty { return 0 }
  if !loaded, pids.isEmpty { return 3 }
  return 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
  fputs("用法：corplink-root-helper <start|stop|status>\n", stderr)
  exit(2)
}

switch arguments[0] {
case "start": exit(startService())
case "stop": exit(stopService())
case "status": exit(printStatus())
default:
  fputs("未知操作：\(arguments[0])\n", stderr)
  exit(2)
}
