import Foundation
import OSLog

// Provides centralized logging with automatic timestamps to eliminate repetitive timestamp formatting.
// Supports optional context labels and log levels for consistent structured logging across the app.

/// Log levels for controlling verbosity
public enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        }
    }
}

/// Minimum severity that produces output. Set to .debug to see routine diagnostics.
public var logMinLevel: LogLevel = .info

/// Logs a message with automatic timestamp
/// - Parameters:
///   - items: Items to print (works like standard print)
///   - context: Optional context label (e.g., "UI", "PhotoSync", "Timeline")
///   - level: Log level (default: .info)
///   - separator: Separator between items (default: space)
///   - terminator: Line terminator (default: newline)
public func log(
    _ items: Any...,
    context: String? = nil,
    level: LogLevel = .info,
    separator: String = " ",
    terminator: String = "\n"
) {
    guard level >= logMinLevel else { return }
    let timestamp = timestamp()
    let levelStr = level.label
    let contextStr = context.map { "[\($0)]" } ?? ""
    
    let message = items.map { "\($0)" }.joined(separator: separator)
    Swift.print("[\(timestamp)][\(levelStr)]\(contextStr) \(message)", terminator: terminator)
}

/// Logs a debug message with automatic timestamp
public func logDebug(
    _ items: Any...,
    context: String? = nil
) {
    let message = items.map { "\($0)" }.joined(separator: " ")
    log(message, context: context, level: .debug)
}

/// Logs a warning message with automatic timestamp
public func logWarning(
    _ items: Any...,
    context: String? = nil
) {
    let message = items.map { "\($0)" }.joined(separator: " ")
    log(message, context: context, level: .warning)
}

/// Logs an error message with automatic timestamp
public func logError(
    _ items: Any...,
    context: String? = nil
) {
    let message = items.map { "\($0)" }.joined(separator: " ")
    log(message, context: context, level: .error)
}

// Generates a timestamp string in format HH:mm:ss.SSS for consistent logging
private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

// Centralizes startup/timeline signposts so Instruments can correlate cold-start milestones.
enum AppSignposts {
    private static let logger = Logger(subsystem: "com.replycant.iosapp", category: "PointsOfInterest")
    private static let signposter = OSSignposter(logger: logger)

    // Starts one signposted interval for the provided startup/timeline phase.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    // Ends one previously started signposted interval.
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    // Emits one milestone event for startup/timeline phases that are point-in-time markers.
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
