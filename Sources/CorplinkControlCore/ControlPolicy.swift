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

public func cleanAdministratorError(_ detail: String) -> String {
  let withoutPrefix = detail.replacingOccurrences(
    of: #"^\d+:\d+:\s*execution error:\s*"#, with: "", options: .regularExpression)
  guard withoutPrefix != detail else { return detail }
  return withoutPrefix.replacingOccurrences(
    of: #"\s+\(-?\d+\)$"#, with: "", options: .regularExpression)
}
