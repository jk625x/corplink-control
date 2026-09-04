import Foundation
import Security

public enum PrivilegedHelperConfiguration {
  public static let protocolVersion = 2
  public static let administratorGroupID: UInt32 = 80
  public static let daemonPlistName = "local.sunyi.corplink-control.root-helper.plist"
  public static let machServiceName = "local.sunyi.corplink-control.root-helper"
  public static let appBundleIdentifier = "local.sunyi.corplink-control"
  public static let helperIdentifier = "local.sunyi.corplink-control.root-helper"

  public static let componentIDs = [
    "connection", "protection", "network-monitor", "data-forwarder", "mdm",
    "network-agent", "app-blocker", "client",
  ]

  public static let allowedActions: Set<String> = {
    var actions: Set<String> = ["start", "stop", "start-suite", "stop-suite", "restore-suite"]
    for componentID in componentIDs {
      actions.insert("start-component:\(componentID)")
      actions.insert("stop-component:\(componentID)")
    }
    return actions
  }()

  public static func isAdministratorMembershipResult(status: Int32, stdout: String) -> Bool {
    status == 0
      && stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        == "user is a member of the group"
  }

  public static func canFallbackAfterTransportFailure(requestSubmitted: Bool) -> Bool {
    !requestSubmitted
  }

  public static func isCompatibleProbe(
    protocolVersion: Int,
    bundleVersion: String,
    expectedBundleVersion: String
  ) -> Bool {
    protocolVersion == Self.protocolVersion
      && !bundleVersion.isEmpty
      && !expectedBundleVersion.isEmpty
      && bundleVersion == bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
      && expectedBundleVersion
        == expectedBundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
      && bundleVersion == expectedBundleVersion
  }

  public static func registrationFingerprint(
    bundleVersion: String, appRequirement: String, helperRequirement: String
  ) -> String {
    "\(bundleVersion)\n\(appRequirement)\n\(helperRequirement)"
  }

  public static func designatedRequirement(at codeURL: URL) -> String? {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(codeURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }
    let validationFlags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
      return nil
    }
    var requirement: SecRequirement?
    guard
      SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
      let requirement
    else { return nil }
    var requirementText: CFString?
    guard
      SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
      let requirementText
    else { return nil }
    return requirementText as String
  }
}

@objc public protocol CorplinkPrivilegedHelperProtocol {
  func probe(withReply reply: @escaping (NSNumber, String) -> Void)

  func perform(
    action: String,
    language: String,
    withReply reply: @escaping (NSNumber, String, String) -> Void)
}
