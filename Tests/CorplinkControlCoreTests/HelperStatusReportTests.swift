import CorplinkControlCore
import Foundation
import Testing

private let validJobIDs = [
  "connection", "protection", "network-monitor", "data-forwarder", "mdm",
  "network-agent", "app-blocker", "client",
]

private func validStatusRows() -> [(String, String)] {
  var rows = validJobIDs.map { ("job.\($0)", "0||-|0|0|1") }
  rows += [
    ("suite_clean", "true"),
    ("suite_runtime_stopped", "true"),
    ("suite_loaded", "0"),
    ("suite_total", "8"),
    ("suite_known_total", "8"),
    ("suite_processes", "0"),
    ("restore_pending", ""),
    ("auxiliary_components", ""),
    ("auxiliary_pids", ""),
    ("vpn", "unavailable"),
    ("swg", "unavailable"),
    ("system_extensions", ""),
    ("client_app_present", "true"),
    ("client_app_running", "false"),
  ]
  return rows
}

private func statusOutput(
  replacing replacements: [String: String] = [:],
  omitting omittedKeys: Set<String> = [],
  appending extraRows: [(String, String)] = []
) -> String {
  let rows = validStatusRows().compactMap { key, value -> (String, String)? in
    guard !omittedKeys.contains(key) else { return nil }
    return (key, replacements[key] ?? value)
  } + extraRows
  return rows.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
}

@Test func statusReportAcceptsAllDocumentedExitStatuses() throws {
  for exitStatus: Int32 in [0, 1, 3] {
    let report = try HelperStatusReport.parse(exitStatus: exitStatus, output: statusOutput())
    #expect(report.exitStatus == exitStatus)
  }
}

@Test func statusReportExposesValidatedValues() throws {
  let output = statusOutput(
    replacing: [
      "job.connection": "1|123:456|schg:uchg|0|0|1",
      "suite_clean": "false",
      "suite_runtime_stopped": "false",
      "suite_loaded": "1",
      "suite_processes": "2",
      "auxiliary_pids": "789,790",
    ],
    appending: [("diagnostic.future", "supported")])
  let report = try HelperStatusReport.parse(exitStatus: 0, output: output)

  #expect(report.values["job.connection"] == "1|123:456|schg:uchg|0|0|1")
  #expect(report.values["suite_loaded"] == "1")
  #expect(report.values["diagnostic.future"] == "supported")
}

@Test func statusReportRejectsUnsupportedExitStatus() {
  #expect(throws: HelperStatusReportParseError.unsupportedExitStatus(2)) {
    try HelperStatusReport.parse(exitStatus: 2, output: statusOutput())
  }
  #expect(throws: HelperStatusReportParseError.unsupportedExitStatus(124)) {
    try HelperStatusReport.parse(exitStatus: 124, output: statusOutput())
  }
}

@Test func statusReportRejectsEmptyOutput() {
  #expect(throws: HelperStatusReportParseError.emptyOutput) {
    try HelperStatusReport.parse(exitStatus: 0, output: " \n\t")
  }
}

@Test func statusReportRejectsMalformedLine() {
  #expect(throws: HelperStatusReportParseError.malformedLine("not-a-pair")) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput() + "not-a-pair\n")
  }
}

@Test func statusReportRejectsMalformedKey() {
  #expect(throws: HelperStatusReportParseError.malformedLine("bad key=value")) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput() + "bad key=value\n")
  }
}

@Test func statusReportRejectsDuplicateKey() {
  #expect(throws: HelperStatusReportParseError.duplicateKey("suite_clean")) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(appending: [("suite_clean", "false")]))
  }
}

@Test func statusReportRejectsMissingScalarKey() {
  #expect(throws: HelperStatusReportParseError.missingKey("suite_processes")) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(omitting: ["suite_processes"]))
  }
}

@Test func statusReportRejectsMissingJob() {
  #expect(throws: HelperStatusReportParseError.missingKey("job.mdm")) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(omitting: ["job.mdm"]))
  }
}

@Test func statusReportRejectsUnexpectedJob() {
  #expect(throws: HelperStatusReportParseError.unexpectedJob("job.unknown")) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(appending: [("job.unknown", "0||-|0|0|1")]))
  }
}

@Test func statusReportRejectsWrongJobFieldCount() {
  let value = "0||-|0|1"
  #expect(
    throws: HelperStatusReportParseError.malformedJob(
      key: "job.connection", value: value)
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["job.connection": value]))
  }
}

@Test func statusReportRejectsMalformedJobBoolean() {
  #expect(
    throws: HelperStatusReportParseError.invalidBoolean(
      key: "job.connection[0]", value: "true")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(replacing: ["job.connection": "true||-|0|0|1"]))
  }
  #expect(
    throws: HelperStatusReportParseError.invalidBoolean(
      key: "job.connection[3]", value: "2")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(replacing: ["job.connection": "0||-|2|0|1"]))
  }
}

@Test func statusReportRejectsMalformedJobPIDList() {
  #expect(
    throws: HelperStatusReportParseError.invalidPIDList(
      key: "job.connection.pids", value: "12::13")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(replacing: ["job.connection": "1|12::13|-|0|0|1"]))
  }
}

@Test func statusReportRejectsDuplicateAndOutOfRangePIDs() {
  #expect(
    throws: HelperStatusReportParseError.invalidPIDList(
      key: "job.connection.pids", value: "12:12")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(replacing: ["job.connection": "1|12:12|-|0|0|1"]))
  }
  #expect(
    throws: HelperStatusReportParseError.invalidPIDList(
      key: "job.connection.pids", value: "999999999999")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0,
      output: statusOutput(
        replacing: ["job.connection": "1|999999999999|-|0|0|1"]))
  }
}

@Test func statusReportRejectsMalformedFlags() {
  let value = "1|12|schg::uchg|0|0|1"
  #expect(
    throws: HelperStatusReportParseError.malformedJob(
      key: "job.connection", value: value)
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["job.connection": value]))
  }
}

@Test func statusReportRejectsNonCanonicalTopLevelBoolean() {
  #expect(
    throws: HelperStatusReportParseError.invalidBoolean(
      key: "suite_clean", value: "1")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["suite_clean": "1"]))
  }
}

@Test func statusReportRejectsInvalidTopLevelIntegers() {
  #expect(
    throws: HelperStatusReportParseError.invalidInteger(
      key: "suite_loaded", value: "-1")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["suite_loaded": "-1"]))
  }
  #expect(
    throws: HelperStatusReportParseError.invalidInteger(
      key: "suite_processes", value: "01")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["suite_processes": "01"]))
  }
}

@Test func statusReportRejectsMalformedAuxiliaryPIDList() {
  #expect(
    throws: HelperStatusReportParseError.invalidPIDList(
      key: "auxiliary_pids", value: "17,-18")
  ) {
    try HelperStatusReport.parse(
      exitStatus: 0, output: statusOutput(replacing: ["auxiliary_pids": "17,-18"]))
  }
}
