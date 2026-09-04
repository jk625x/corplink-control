import CorplinkControlCore
import Foundation
import Testing

@Test func privilegedHelperOnlyAllowsKnownActions() {
  #expect(PrivilegedHelperConfiguration.componentIDs.count == 8)
  #expect(PrivilegedHelperConfiguration.allowedActions.contains("start-suite"))
  #expect(PrivilegedHelperConfiguration.allowedActions.contains("stop-component:connection"))
  #expect(!PrivilegedHelperConfiguration.allowedActions.contains("stop-component:unknown"))
  #expect(!PrivilegedHelperConfiguration.allowedActions.contains("/bin/sh"))
}

@Test func designatedRequirementLookupFailsClosed() {
  let missingCode = URL(fileURLWithPath: "/definitely-not-a-signed-program")
  #expect(PrivilegedHelperConfiguration.designatedRequirement(at: missingCode) == nil)
  #expect(
    PrivilegedHelperConfiguration.designatedRequirement(
      at: URL(fileURLWithPath: CommandLine.arguments[0])) != nil)
}

@Test func administratorMembershipParsingFailsClosed() {
  #expect(PrivilegedHelperConfiguration.administratorGroupID == 80)
  #expect(
    PrivilegedHelperConfiguration.isAdministratorMembershipResult(
      status: 0, stdout: "user is a member of the group\n"))
  #expect(
    !PrivilegedHelperConfiguration.isAdministratorMembershipResult(
      status: 0, stdout: "user is not a member of the group\n"))
  #expect(
    !PrivilegedHelperConfiguration.isAdministratorMembershipResult(
      status: 1, stdout: "user is a member of the group\n"))
}

@Test func transportFallbackIsAllowedOnlyBeforeSubmission() {
  #expect(
    PrivilegedHelperConfiguration.canFallbackAfterTransportFailure(requestSubmitted: false))
  #expect(
    !PrivilegedHelperConfiguration.canFallbackAfterTransportFailure(requestSubmitted: true))
}

@Test func registrationFingerprintChangesAcrossBuildsAndSignatures() {
  let original = PrivilegedHelperConfiguration.registrationFingerprint(
    bundleVersion: "11", appRequirement: "identifier app and cdhash A1",
    helperRequirement: "identifier helper and cdhash H1")
  #expect(
    original
      == PrivilegedHelperConfiguration.registrationFingerprint(
        bundleVersion: "11", appRequirement: "identifier app and cdhash A1",
        helperRequirement: "identifier helper and cdhash H1"))
  #expect(
    original
      != PrivilegedHelperConfiguration.registrationFingerprint(
        bundleVersion: "12", appRequirement: "identifier app and cdhash A1",
        helperRequirement: "identifier helper and cdhash H1"))
  #expect(
    original
      != PrivilegedHelperConfiguration.registrationFingerprint(
        bundleVersion: "11", appRequirement: "identifier app and cdhash A2",
        helperRequirement: "identifier helper and cdhash H1"))
  #expect(
    original
      != PrivilegedHelperConfiguration.registrationFingerprint(
        bundleVersion: "11", appRequirement: "identifier app and cdhash A1",
        helperRequirement: "identifier helper and cdhash H2"))
}

@Test func helperProtocolVersionIsCurrent() {
  #expect(PrivilegedHelperConfiguration.protocolVersion == 2)
}

@Test func compatibleProbeRequiresMatchingProtocolAndBuild() {
  #expect(
    PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: "11", expectedBundleVersion: "11"))
}

@Test func incompatibleProbeRejectsOldProtocol() {
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 1, bundleVersion: "11", expectedBundleVersion: "11"))
}

@Test func incompatibleProbeRejectsDifferentBuild() {
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: "10", expectedBundleVersion: "11"))
}

@Test func incompatibleProbeRejectsMissingBuildVersions() {
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: "", expectedBundleVersion: ""))
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: "11", expectedBundleVersion: ""))
}

@Test func incompatibleProbeRejectsWhitespacePaddedBuildVersions() {
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: " 11", expectedBundleVersion: " 11"))
  #expect(
    !PrivilegedHelperConfiguration.isCompatibleProbe(
      protocolVersion: 2, bundleVersion: "11 ", expectedBundleVersion: "11 "))
}
