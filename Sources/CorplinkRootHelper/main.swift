import Darwin
import Foundation

private let serviceLabel = "com.volcengine.corplink.service"
private let serviceTarget = "system/\(serviceLabel)"
private let plistPath = "/Library/LaunchDaemons/\(serviceLabel).plist"
private let executablePath = "/usr/local/corplink/corplink-service"

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

    let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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

private func clearImmutableFlags() -> Bool {
    let protected = plistFlags().intersection(["schg", "uchg"])
    for flag in protected.sorted() {
        print("正在移除 plist 属性：\(flag)")
        let result = run("/usr/bin/chflags", ["no\(flag)", plistPath])
        if result.status != 0 {
            fputs("无法移除 \(flag)：\(result.stderr)\n", stderr)
            return false
        }
    }
    return plistFlags().isDisjoint(with: ["schg", "uchg"])
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
    guard clearImmutableFlags() else {
        fputs("无法清除 plist 的不可变属性。\n", stderr)
        return 1
    }

    if loadedBefore {
        var result = run("/bin/launchctl", ["bootout", serviceTarget])
        if result.status != 0 {
            result = run("/bin/launchctl", ["bootout", "system", plistPath])
        }
        guard result.status == 0 else {
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
        fputs("停止后验证失败。\n", stderr)
        return 1
    }
    print("服务已停止且已卸载。")
    return 0
}

private func printStatus() -> Int32 {
    let loaded = isLoaded()
    let pids = servicePIDs()
    let flags = plistFlags().sorted()
    print("loaded=\(loaded ? "true" : "false")")
    print("pids=\(pids.map(String.init).joined(separator: ","))")
    print("flags=\(flags.joined(separator: ","))")
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
