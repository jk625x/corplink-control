import Foundation
import Testing
@testable import CorplinkControlCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private func plist(at relativePath: String) throws -> [String: Any] {
  let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
  let value = try PropertyListSerialization.propertyList(from: data, format: nil)
  return try #require(value as? [String: Any])
}

@Test func releaseVersionAndBuildAreExpected() throws {
  let info = try plist(at: "Info.plist")
  #expect(info["CFBundleIdentifier"] as? String == PrivilegedHelperConfiguration.appBundleIdentifier)
  #expect(info["CFBundleShortVersionString"] as? String == "1.6.1")
  #expect(info["CFBundleVersion"] as? String == "11")
  #expect(info["LSMinimumSystemVersion"] as? String == "13.0")
}

@Test func launchDaemonMetadataMatchesProtocolConstants() throws {
  let daemon = try plist(
    at: "Resources/\(PrivilegedHelperConfiguration.daemonPlistName)")
  #expect(daemon["Label"] as? String == PrivilegedHelperConfiguration.machServiceName)
  #expect(
    daemon["AssociatedBundleIdentifiers"] as? [String]
      == [PrivilegedHelperConfiguration.appBundleIdentifier])
  #expect(
    (daemon["MachServices"] as? [String: Bool])?[PrivilegedHelperConfiguration.machServiceName]
      == true)
}

@Test func launchDaemonUsesOnlyTheEmbeddedHelper() throws {
  let daemon = try plist(
    at: "Resources/\(PrivilegedHelperConfiguration.daemonPlistName)")
  #expect(daemon["BundleProgram"] as? String == "Contents/Resources/corplink-root-helper")
  #expect(
    daemon["ProgramArguments"] as? [String]
      == ["Contents/Resources/corplink-root-helper", "--daemon"])
  #expect(daemon["RunAtLoad"] as? Bool == false)
  #expect(daemon["KeepAlive"] as? Bool == false)
}

@Test func statusSchemaCoversEveryPrivilegedComponent() {
  #expect(
    Set(HelperStatusReport.requiredJobIDs)
      == Set(PrivilegedHelperConfiguration.componentIDs))
  #expect(HelperStatusReport.requiredJobIDs.count == 8)
}
