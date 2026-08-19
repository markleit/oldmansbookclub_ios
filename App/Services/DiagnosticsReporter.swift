import Foundation
import MetricKit
import CryptoKit

// #100 — first-party crash/hang/perf reporting via MetricKit (no third-party SDK).
// Subscribes on launch; iOS delivers diagnostics on the NEXT launch after an event, batched
// (~once/day). For each diagnostic we POST a compact report to /diagnostics, and the server
// auto-files a GitHub issue deduped by call-stack signature.
//
// NOTE: MetricKit does not deliver diagnostics on the Simulator — reports only appear from a
// real device.
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsReporter()
    private override init() { super.init() }

    func start() {
        MXMetricManager.shared.add(self)
    }

    // Required by MXMetricManagerSubscriber; we don't act on aggregate metric payloads.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            payload.crashDiagnostics?.forEach { report(kind: "crash", diagnostic: $0) }
            payload.hangDiagnostics?.forEach { report(kind: "hang", diagnostic: $0) }
            payload.cpuExceptionDiagnostics?.forEach { report(kind: "cpu", diagnostic: $0) }
            payload.diskWriteExceptionDiagnostics?.forEach { report(kind: "disk", diagnostic: $0) }
        }
    }

    private func report(kind: String, diagnostic: MXDiagnostic) {
        let md = diagnostic.metaData
        let report = APIClient.DiagnosticReport(
            kind: kind,
            signature: Self.signature(kind: kind, diagnostic: diagnostic),
            summary: Self.summary(kind: kind, diagnostic: diagnostic),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: md.applicationBuildVersion,
            osVersion: md.osVersion,
            deviceModel: md.deviceType,
            payloadJson: String(data: diagnostic.jsonRepresentation(), encoding: .utf8)
        )
        Task { try? await APIClient.shared.reportDiagnostic(report) }
    }

    // Stable dedup key: hash the call-stack tree (identical across recurrences of the same
    // crash) rather than the full payload, which carries per-event timestamps. callStackTree
    // lives on the concrete subclasses, not the MXDiagnostic base — fall back to the full
    // payload if a future kind isn't covered.
    private static func signature(kind: String, diagnostic: MXDiagnostic) -> String {
        let basis = callStackJSON(diagnostic) ?? diagnostic.jsonRepresentation()
        let digest = SHA256.hash(data: Data(kind.utf8) + basis)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func callStackJSON(_ d: MXDiagnostic) -> Data? {
        switch d {
        case let c as MXCrashDiagnostic:             return c.callStackTree.jsonRepresentation()
        case let h as MXHangDiagnostic:              return h.callStackTree.jsonRepresentation()
        case let cpu as MXCPUExceptionDiagnostic:    return cpu.callStackTree.jsonRepresentation()
        case let disk as MXDiskWriteExceptionDiagnostic: return disk.callStackTree.jsonRepresentation()
        default: return nil
        }
    }

    private static func summary(kind: String, diagnostic: MXDiagnostic) -> String {
        if let crash = diagnostic as? MXCrashDiagnostic {
            let parts = [
                crash.terminationReason,
                crash.exceptionType.map { "excType \($0)" },
                crash.signal.map { "signal \($0)" }
            ].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? "crash" : parts.joined(separator: " · ")
        }
        switch kind {
        case "hang": return "app hang"
        case "cpu":  return "CPU exception"
        case "disk": return "excessive disk writes"
        default:     return kind
        }
    }
}
