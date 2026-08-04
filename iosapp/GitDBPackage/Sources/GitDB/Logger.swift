import Foundation

// Provides lightweight logging functions required by shared security and sync components.
func log(_ message: String, context: String = "GitDB") {
    print("[\(context)] \(message)")
}

// Provides lightweight warning logging.
func logWarning(_ message: String, context: String = "GitDB") {
    print("[\(context)] WARNING: \(message)")
}

// Provides lightweight error logging.
func logError(_ message: String, context: String = "GitDB") {
    print("[\(context)] ERROR: \(message)")
}

// Provides lightweight debug logging.
func logDebug(_ message: String, context: String = "GitDB") {
    print("[\(context)] DEBUG: \(message)")
}
