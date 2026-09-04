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

@Test func launchctlPrintOnlyTreatsExplicitServiceAbsenceAsNotLoaded() {
  #expect(LaunchctlPrintDecision.evaluate(exitStatus: 0) == .loaded)
  #expect(LaunchctlPrintDecision.evaluate(exitStatus: 113) == .notLoaded)
  #expect(LaunchctlPrintDecision.evaluate(exitStatus: 124) == .failed(124))
  #expect(LaunchctlPrintDecision.evaluate(exitStatus: 1) == .failed(1))
}

@Test func helperUnregistrationRequiresBothAPIsToReportAbsence() {
  #expect(
    HelperUnregistrationDecision.evaluate(
      serviceManagementInactive: true, launchctlExitStatus: 113) == .complete)
  #expect(
    HelperUnregistrationDecision.evaluate(
      serviceManagementInactive: false, launchctlExitStatus: 113) == .waiting)
  #expect(
    HelperUnregistrationDecision.evaluate(
      serviceManagementInactive: true, launchctlExitStatus: 0) == .waiting)
  #expect(
    HelperUnregistrationDecision.evaluate(
      serviceManagementInactive: true, launchctlExitStatus: 124) == .inspectionFailed(124))
}

@Test func pgrepOnlyTreatsExitOneAsNoMatches() {
  #expect(PgrepDecision.evaluate(exitStatus: 0) == .matches)
  #expect(PgrepDecision.evaluate(exitStatus: 1) == .noMatches)
  #expect(PgrepDecision.evaluate(exitStatus: 124) == .failed(124))
  #expect(PgrepDecision.evaluate(exitStatus: 2) == .failed(2))
}

@Test func zeroExitCommandsFailClosedOnTimeoutOrOtherErrors() {
  #expect(ZeroExitCommandDecision.evaluate(exitStatus: 0) == .succeeded)
  #expect(ZeroExitCommandDecision.evaluate(exitStatus: 124) == .failed(124))
  #expect(ZeroExitCommandDecision.evaluate(exitStatus: 1) == .failed(1))
}

@Test func statusInspectionFailuresUseANonSemanticExitStatus() {
  #expect(HelperInspectionFailurePolicy.exitStatus(for: "status") == 70)
  #expect(HelperInspectionFailurePolicy.exitStatus(for: "stop-suite") == 1)
  #expect(HelperInspectionFailurePolicy.exitStatus(for: "start-component:connection") == 1)
}

@Test func administratorWrapperIsRemovedWithoutChangingRealErrors() {
  #expect(
    cleanAdministratorError(
      "0:170: execution error: 客户端登录项：找不到 plist，且没有可用的停止前备份 (1)")
      == "客户端登录项：找不到 plist，且没有可用的停止前备份")
  #expect(cleanAdministratorError("launchctl bootout failed") == "launchctl bootout failed")
}

@Test func stopConvergesWhenNoResidueRemains() {
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 0, processCount: 0, retriesPerformed: 0) == .converged)
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 0, processCount: 0, retriesPerformed: 1) == .converged)
}

@Test func stopAllowsOneRetryForLoadedJobResidue() {
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 1, processCount: 0, retriesPerformed: 0) == .retry)
}

@Test func stopAllowsOneRetryForProcessResidue() {
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 0, processCount: 2, retriesPerformed: 0) == .retry)
}

@Test func stopFailsWhenResidueRemainsAfterRetry() {
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 1, processCount: 1, retriesPerformed: 1) == .failed)
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 1, processCount: 1, retriesPerformed: 2) == .failed)
}

@Test func stopConvergenceFailsClosedForInvalidCounts() {
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: -1, processCount: 0, retriesPerformed: 0) == .failed)
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 0, processCount: -1, retriesPerformed: 0) == .failed)
  #expect(
    StopConvergenceDecision.evaluate(
      loadedJobCount: 0, processCount: 0, retriesPerformed: -1) == .failed)
}
