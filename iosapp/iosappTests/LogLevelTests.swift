import OSLog
import Testing
@testable import LibGit2
@testable import iosapp

// The phone only fails this way once the debugger has detached, so the
// severity has to land on the matching unified-log level or Console.app
// filters hide the line that explains the failure.
struct LogLevelTests {
    @Test func errorAndDebugMapToTheMatchingSystemLogType() {
        #expect(LogLevel.error.osLogType == .error)
        #expect(LogLevel.debug.osLogType == .debug)
        #expect(osLogType(forLevel: "ERROR") == .error)
        #expect(osLogType(forLevel: "DEBUG") == .debug)
    }

    @Test func warningsAreNoticesRatherThanErrors() {
        #expect(LogLevel.warning.osLogType == .default)
        #expect(LogLevel.info.osLogType == .info)
        #expect(osLogType(forLevel: "WARNING") == .default)
        #expect(osLogType(forLevel: "INFO") == .info)
    }
}
