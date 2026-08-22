import AppKit
import SwiftUI

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
            let processText = pids.isEmpty ? "无进程" : "PID \(pids.map(String.init).joined(separator: ", "))"
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
        state = .loading
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
        let values = Dictionary(uniqueKeysWithValues: result.stdout.split(separator: "\n").compactMap { row in
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

    nonisolated private static func run(_ executable: URL, arguments: [String]) async -> CommandResult {
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
                stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }.value
    }

    nonisolated private static func runWithAdministratorPrivileges(_ helper: URL, action: String) async -> CommandResult {
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

private struct ContentView: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: controller.state.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(controller.state.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.state.title).font(.headline)
                    Text(controller.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !controller.flags.isEmpty {
                Label("plist 属性：\(controller.flags.joined(separator: ", "))", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = controller.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(controller.isError ? .red : .secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button {
                    controller.perform("start")
                } label: {
                    Label("启动", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy || controller.state.isRunning)

                Button {
                    controller.perform("stop")
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(controller.isBusy || controller.state.isStopped)
            }

            Divider()

            HStack {
                Button("刷新") { controller.refresh() }
                    .disabled(controller.isBusy)
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button("退出") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 330)
        .task { controller.refresh() }
    }
}

@main
private struct CorplinkControlApp: App {
    @StateObject private var controller = ServiceController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: controller.state.symbol)
                .accessibilityLabel("飞连控制")
        }
        .menuBarExtraStyle(.window)
    }
}
