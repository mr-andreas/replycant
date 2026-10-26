import Foundation
import LibGit2

// Forwards one line to the debugger and to the app's shareable log.
// GitDB does not own that file; the app installs the sink at launch.
private func emitDiagnostic(_ line: String) {
    print(line)
    diagnosticLogSink?(line)
}

// Provides lightweight logging functions required by shared security and sync components.
func log(_ message: String, context: String = "GitDB") {
    emitDiagnostic("[\(context)] \(message)")
}

// Provides lightweight warning logging.
func logWarning(_ message: String, context: String = "GitDB") {
    emitDiagnostic("[\(context)] WARNING: \(message)")
}

// Provides lightweight error logging.
func logError(_ message: String, context: String = "GitDB") {
    emitDiagnostic("[\(context)] ERROR: \(message)")
}

// Provides lightweight debug logging.
func logDebug(_ message: String, context: String = "GitDB") {
    emitDiagnostic("[\(context)] DEBUG: \(message)")
}
