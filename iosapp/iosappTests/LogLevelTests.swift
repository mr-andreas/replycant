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

    // Console.app names the process from the executable. Hosted unit tests
    // run inside the app, so the host bundle is the name a developer sees.
    @Test func processNameIsReplycant() {
        let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
        #expect(executable == "replycant")
    }

    // One subsystem for the whole app, so Console.app can show every line
    // with a single filter instead of a per-loader guess.
    @Test func appLogsUseTheReplycantSubsystem() {
        #expect(appLogSubsystem == "com.replycant.app")
    }
}
