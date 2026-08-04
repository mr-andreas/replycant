import Foundation

// Error type used when an operation requires a missing registration or unsupported manifest shape.
public struct NotSupportedError: Error {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
