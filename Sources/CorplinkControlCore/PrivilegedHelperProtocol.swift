import Foundation
import Security

public enum PrivilegedHelperConfiguration {
  public static let daemonPlistName = "local.sunyi.corplink-control.root-helper.plist"
  public static let machServiceName = "local.sunyi.corplink-control.root-helper"
  public static let appBundleIdentifier = "local.sunyi.corplink-control"
  public static let helperIdentifier = "local.sunyi.corplink-control.root-helper"

  private static let componentIDs = [
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
  func perform(
    action: String,
    language: String,
    withReply reply: @escaping (NSNumber, String, String) -> Void)
}
