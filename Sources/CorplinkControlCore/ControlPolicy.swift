import Foundation

public struct ComponentFacts: Equatable, Sendable {
  public let plistPresent: Bool
  public let loaded: Bool
  public let processCount: Int
  public let pendingRestore: Bool

  public init(
    plistPresent: Bool, loaded: Bool, processCount: Int, pendingRestore: Bool
  ) {
    self.plistPresent = plistPresent
    self.loaded = loaded
    self.processCount = processCount
    self.pendingRestore = pendingRestore
  }

  public var isInstalled: Bool {
    plistPresent || loaded || processCount > 0 || pendingRestore
  }

  public var hasLaunchJobEvidence: Bool {
    plistPresent || loaded || pendingRestore
  }
}

public enum SuiteRuntimeState: Equatable, Sendable {
  case runningOrResidual
  case stoppedWithActiveExtensions
  case cleanlyStopped

  public static func classify(
    loadedJobs: Int, processCount: Int, activeSystemExtensions: Int
  ) -> Self {
    guard loadedJobs == 0, processCount == 0 else { return .runningOrResidual }
    return activeSystemExtensions == 0 ? .cleanlyStopped : .stoppedWithActiveExtensions
  }

  public var runtimeStopped: Bool {
    self != .runningOrResidual
  }
}

public enum LaunchctlPrintDecision: Equatable, Sendable {
  case loaded
  case notLoaded
  case failed(Int32)

  public static func evaluate(exitStatus: Int32) -> Self {
    switch exitStatus {
    case 0: return .loaded
    case 113: return .notLoaded
    default: return .failed(exitStatus)
    }
  }
}

public enum HelperUnregistrationDecision: Equatable, Sendable {
  case complete
  case waiting
  case inspectionFailed(Int32)

  public static func evaluate(
    serviceManagementInactive: Bool, launchctlExitStatus: Int32
  ) -> Self {
    switch LaunchctlPrintDecision.evaluate(exitStatus: launchctlExitStatus) {
    case .loaded:
      return .waiting
    case .notLoaded:
      return serviceManagementInactive ? .complete : .waiting
    case .failed(let status):
      return .inspectionFailed(status)
    }
  }
}

public enum PgrepDecision: Equatable, Sendable {
  case matches
  case noMatches
  case failed(Int32)

  public static func evaluate(exitStatus: Int32) -> Self {
    switch exitStatus {
    case 0: return .matches
    case 1: return .noMatches
    default: return .failed(exitStatus)
    }
  }
}

public enum ZeroExitCommandDecision: Equatable, Sendable {
  case succeeded
  case failed(Int32)

  public static func evaluate(exitStatus: Int32) -> Self {
    exitStatus == 0 ? .succeeded : .failed(exitStatus)
  }
}

public enum HelperInspectionFailurePolicy {
  public static func exitStatus(for command: String) -> Int32 {
    command == "status" ? 70 : 1
  }
}

public enum HelperStatusReportParseError: Error, Equatable, Sendable {
  case unsupportedExitStatus(Int32)
  case emptyOutput
  case malformedLine(String)
  case duplicateKey(String)
  case missingKey(String)
  case unexpectedJob(String)
  case malformedJob(key: String, value: String)
  case invalidBoolean(key: String, value: String)
  case invalidInteger(key: String, value: String)
  case invalidPIDList(key: String, value: String)
}

public struct HelperStatusReport: Equatable, Sendable {
  public static let requiredJobIDs = PrivilegedHelperConfiguration.componentIDs

  private static let requiredScalarKeys = [
    "suite_clean", "suite_runtime_stopped", "suite_loaded", "suite_total",
    "suite_known_total", "suite_processes", "restore_pending", "auxiliary_components",
    "auxiliary_pids", "vpn", "swg", "system_extensions", "client_app_present",
    "client_app_running",
  ]
  private static let booleanKeys = [
    "suite_clean", "suite_runtime_stopped", "client_app_present", "client_app_running",
  ]
  private static let integerKeys = [
    "suite_loaded", "suite_total", "suite_known_total", "suite_processes",
  ]

  public let exitStatus: Int32
  public let values: [String: String]

  private init(exitStatus: Int32, values: [String: String]) {
    self.exitStatus = exitStatus
    self.values = values
  }

  public static func parse(exitStatus: Int32, output: String) throws -> Self {
    guard [Int32(0), 1, 3].contains(exitStatus) else {
      throw HelperStatusReportParseError.unsupportedExitStatus(exitStatus)
    }
    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HelperStatusReportParseError.emptyOutput
    }

    var values: [String: String] = [:]
    for rawLine in output.split(whereSeparator: \Character.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: "=") else {
        throw HelperStatusReportParseError.malformedLine(line)
      }
      let key = String(line[..<separator])
      let value = String(line[line.index(after: separator)...])
      guard
        !key.isEmpty,
        key == key.trimmingCharacters(in: .whitespaces),
        key.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
      else {
        throw HelperStatusReportParseError.malformedLine(line)
      }
      guard values[key] == nil else {
        throw HelperStatusReportParseError.duplicateKey(key)
      }
      values[key] = value
    }

    let requiredKeys = requiredJobIDs.map { "job.\($0)" } + requiredScalarKeys
    for key in requiredKeys where values[key] == nil {
      throw HelperStatusReportParseError.missingKey(key)
    }

    let knownJobKeys = Set(requiredJobIDs.map { "job.\($0)" })
    for key in values.keys where key.hasPrefix("job.") && !knownJobKeys.contains(key) {
      throw HelperStatusReportParseError.unexpectedJob(key)
    }

    for jobID in requiredJobIDs {
      let key = "job.\(jobID)"
      guard let value = values[key] else {
        throw HelperStatusReportParseError.missingKey(key)
      }
      try validateJob(key: key, value: value)
    }

    for key in booleanKeys {
      guard let value = values[key], value == "true" || value == "false" else {
        throw HelperStatusReportParseError.invalidBoolean(
          key: key, value: values[key] ?? "")
      }
    }
    for key in integerKeys {
      guard let value = values[key], isCanonicalNonnegativeInteger(value) else {
        throw HelperStatusReportParseError.invalidInteger(
          key: key, value: values[key] ?? "")
      }
    }
    guard let auxiliaryPIDs = values["auxiliary_pids"] else {
      throw HelperStatusReportParseError.missingKey("auxiliary_pids")
    }
    try validatePIDList(key: "auxiliary_pids", value: auxiliaryPIDs, separator: ",")

    return Self(exitStatus: exitStatus, values: values)
  }

  private static func validateJob(key: String, value: String) throws {
    let fields = value.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
      .map(String.init)
    guard fields.count == 6 else {
      throw HelperStatusReportParseError.malformedJob(key: key, value: value)
    }
    for fieldIndex in [0, 3, 4, 5] where fields[fieldIndex] != "0" && fields[fieldIndex] != "1" {
      throw HelperStatusReportParseError.invalidBoolean(
        key: "\(key)[\(fieldIndex)]", value: fields[fieldIndex])
    }
    try validatePIDList(key: "\(key).pids", value: fields[1], separator: ":")
    guard isValidFlagsField(fields[2]) else {
      throw HelperStatusReportParseError.malformedJob(key: key, value: value)
    }
  }

  private static func validatePIDList(key: String, value: String, separator: Character) throws {
    guard !value.isEmpty else { return }
    let parts = value.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    var seen: Set<Int32> = []
    for part in parts {
      guard
        part.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
        let pid = Int32(part),
        seen.insert(pid).inserted
      else {
        throw HelperStatusReportParseError.invalidPIDList(key: key, value: value)
      }
    }
  }

  private static func isCanonicalNonnegativeInteger(_ value: String) -> Bool {
    value.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
      && Int(value) != nil
  }

  private static func isValidFlagsField(_ value: String) -> Bool {
    if value.isEmpty || value == "-" { return true }
    return value.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { flag in
      !flag.isEmpty
        && flag.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
  }
}

public enum StopConvergenceDecision: Equatable, Sendable {
  case converged
  case retry
  case failed

  public static func evaluate(
    loadedJobCount: Int,
    processCount: Int,
    retriesPerformed: Int
  ) -> Self {
    guard loadedJobCount >= 0, processCount >= 0, retriesPerformed >= 0 else { return .failed }
    guard loadedJobCount > 0 || processCount > 0 else { return .converged }
    return retriesPerformed == 0 ? .retry : .failed
  }
}

public func cleanAdministratorError(_ detail: String) -> String {
  let withoutPrefix = detail.replacingOccurrences(
    of: #"^\d+:\d+:\s*execution error:\s*"#, with: "", options: .regularExpression)
  guard withoutPrefix != detail else { return detail }
  return withoutPrefix.replacingOccurrences(
    of: #"\s+\(-?\d+\)$"#, with: "", options: .regularExpression)
}
