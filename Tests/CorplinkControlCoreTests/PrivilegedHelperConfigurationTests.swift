import CorplinkControlCore
import Foundation
import Testing

@Test func privilegedHelperOnlyAllowsKnownActions() {
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
