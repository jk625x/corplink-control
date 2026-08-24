import Testing
@testable import CorplinkControlCore

@Test func componentPresenceUsesRuntimeAndRecoveryEvidence() {
  #expect(
    !ComponentFacts(
      plistPresent: false, loaded: false, processCount: 0, pendingRestore: false
    ).isInstalled)
  #expect(
    ComponentFacts(
      plistPresent: true, loaded: false, processCount: 0, pendingRestore: false
    ).isInstalled)
  #expect(
    ComponentFacts(
      plistPresent: false, loaded: true, processCount: 0, pendingRestore: false
    ).isInstalled)
  #expect(
    ComponentFacts(
      plistPresent: false, loaded: false, processCount: 1, pendingRestore: false
    ).isInstalled)
  #expect(
    ComponentFacts(
      plistPresent: false, loaded: false, processCount: 0, pendingRestore: true
    ).isInstalled)
}

@Test func clientProcessAloneDoesNotInventALegacyLaunchJob() {
  let modernClient = ComponentFacts(
    plistPresent: false, loaded: false, processCount: 1, pendingRestore: false)
  #expect(modernClient.isInstalled)
  #expect(!modernClient.hasLaunchJobEvidence)
}

@Test func activeExtensionIsAStoppedWarningState() {
  #expect(
    SuiteRuntimeState.classify(
      loadedJobs: 0, processCount: 0, activeSystemExtensions: 1
    ) == .stoppedWithActiveExtensions)
  #expect(
    SuiteRuntimeState.stoppedWithActiveExtensions.runtimeStopped)
}

@Test func realRuntimeResidueStillPreventsStoppedState() {
  #expect(
    SuiteRuntimeState.classify(
      loadedJobs: 1, processCount: 0, activeSystemExtensions: 0
    ) == .runningOrResidual)
  #expect(
    SuiteRuntimeState.classify(
      loadedJobs: 0, processCount: 1, activeSystemExtensions: 0
    ) == .runningOrResidual)
  #expect(!SuiteRuntimeState.runningOrResidual.runtimeStopped)
}

@Test func noRuntimeOrExtensionIsCleanlyStopped() {
  #expect(
    SuiteRuntimeState.classify(
      loadedJobs: 0, processCount: 0, activeSystemExtensions: 0
    ) == .cleanlyStopped)
}

@Test func administratorWrapperIsRemovedWithoutChangingRealErrors() {
  #expect(
    cleanAdministratorError(
      "0:170: execution error: 客户端登录项：找不到 plist，且没有可用的停止前备份 (1)")
      == "客户端登录项：找不到 plist，且没有可用的停止前备份")
  #expect(cleanAdministratorError("launchctl bootout failed") == "launchctl bootout failed")
}
