import Foundation
import GitDB
import LibGit2
import Security

/// Owns the app's single tailnet node and brings it up when there is one to
/// bring up.
///
/// gitd publishes no host ports, so on a tailnet deployment every request the
/// app makes depends on membership. A userspace node only runs while the app
/// does, which means joining is part of startup rather than a one-time setup
/// step, and requests issued before the node is up are refused.
///
/// A device that has not paired yet has no tailnet configuration, so every
/// entry point here is a no-op when nothing is stored.
actor TailnetBootstrap {
    static let shared = TailnetBootstrap()

    enum BootstrapError: LocalizedError, Equatable {
        case missingPinnedCA
        case missingDeviceIdentity
        /// The launch join did not finish in time. Not a failure: it keeps
        /// running and the node is installed when it comes up.
        case stillConnecting

        var errorDescription: String? {
            switch self {
            case .missingPinnedCA:
                return "This device has no pinned CA, so it cannot verify the tailnet control plane."
            case .missingDeviceIdentity:
                return "This device has no identity, so the tailnet control plane would reject it."
            case .stillConnecting:
                return "Still connecting to your library's network."
            }
        }
    }

    private static let statusPollInterval: Duration = .seconds(10)

    /// How long launch waits for the node. Long enough that an online launch
    /// comes up before the first request, short enough that an offline one
    /// still reaches the local library promptly.
    static let launchJoinTimeout: Duration = .seconds(10)

    private let configurations: TailnetConfigurationManager
    private let router: TailnetSessionRouter
    private let rejoinOverride: (@Sendable (TailnetConfiguration) async throws -> Void)?
    private var manager: TailnetManager?
    private var launchJoin: Task<Void, Error>?
    private var statusWatch: Task<Void, Never>?
    private var lastLoggedStatus: TailnetStatusReport?
    private var lastStatusError: String?

    /// - Parameter rejoin: replaces the real rejoin, so tests can stand in
    ///   for a node that never comes up.
    init(
        configurations: TailnetConfigurationManager = .shared,
        router: TailnetSessionRouter = .shared,
        rejoin: (@Sendable (TailnetConfiguration) async throws -> Void)? = nil
    ) {
        self.configurations = configurations
        self.router = router
        self.rejoinOverride = rejoin
    }

    /// Where tsnet persists the node's machine key and peer state.
    ///
    /// Application Support rather than Documents: it must survive launches, or
    /// every start would register a new node and the deployment would
    /// accumulate dead ones, but it is not user-visible data.
    static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tailnet", isDirectory: true)
    }

    /// Whether this deployment is reached over a tailnet at all.
    var isConfigured: Bool { configurations.load() != nil }

    /// Brings the tailnet up if this device is paired to one, and does nothing
    /// otherwise.
    ///
    /// Waits at most `timeout`, then throws `stillConnecting` while the join
    /// carries on: libtailscale cannot cancel a node that is coming up, so an
    /// offline launch would otherwise never reach the local library. Until
    /// the node is up the router refuses requests rather than dialling
    /// directly, and concurrent callers share the one join in flight.
    ///
    /// A rejoin carries no pre-auth key: the node re-authenticates from the
    /// state directory, and mints a fresh key through hsproxy if headscale has
    /// lost track of it.
    func ensureJoinedIfConfigured(timeout: Duration = launchJoinTimeout) async throws {
        guard let configuration = configurations.load() else { return }
        if let manager, await manager.isJoined { return }

        let join: Task<Void, Error>
        if let launchJoin {
            join = launchJoin
        } else {
            router.expectTailnet()
            // Inherits this actor, so it cannot start before `launchJoin` is
            // set, and clearing it afterwards lets a failed join be retried.
            join = Task {
                defer { launchJoin = nil }
                try await rejoin(configuration)
            }
            launchJoin = join
        }
        try await Self.wait(for: join, timeout: timeout)
    }

    private func rejoin(_ configuration: TailnetConfiguration) async throws {
        if let rejoinOverride {
            try await rejoinOverride(configuration)
            return
        }
        try await join(configuration: configuration, preauthKey: nil, onProgress: nil)
    }

    /// Waits for a join without being held by it. Awaiting the task's value
    /// directly cannot be abandoned, which is exactly the hang this avoids.
    private static func wait(for join: Task<Void, Error>, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome = JoinOutcome(continuation)
            Task {
                do {
                    try await join.value
                    outcome.resolve(.success(()))
                } catch {
                    outcome.resolve(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                outcome.resolve(.failure(BootstrapError.stillConnecting))
            }
        }
    }

    /// Joins for the first time, from a freshly opened pairing record.
    ///
    /// The record carries no tailnet key: this device's key is already in
    /// `pubkeys/` by the time the record appears, and that is what lets it
    /// mint its own key through hsproxy.
    ///
    /// Persists the configuration only after the join succeeds, so a record
    /// that cannot actually be used does not leave the app trying to rejoin a
    /// tailnet it never reached.
    func joinAndPersist(
        payload: PairingRecord.Payload,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await joinAndPersist(
            headscaleURL: payload.headscaleURL,
            preauthKey: nil,
            onProgress: onProgress
        )
    }

    /// Joins from the first-device CA QR, which carries a live pre-auth key
    /// rather than a sealed pairing record. The first device has no entry in
    /// `pubkeys/` yet, so it cannot mint one itself.
    func joinAndPersist(
        headscaleURL: String,
        preauthKey: String?,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let configuration = try TailnetConfigurationManager.from(headscaleURL: headscaleURL)
        try await join(
            configuration: configuration,
            preauthKey: preauthKey,
            onProgress: onProgress
        )
        configurations.save(configuration)
    }

    /// Takes the node down and forgets the deployment. Used when a device is
    /// unpaired or its state is wiped.
    func leave() async {
        statusWatch?.cancel()
        statusWatch = nil
        lastLoggedStatus = nil
        lastStatusError = nil
        await manager?.shutDown()
        manager = nil
        router.use(nil)
        configurations.clear()
    }

    /// How this device is connected, or nil when there is no tailnet to
    /// describe - a LAN deployment, or a paired device whose node has not come
    /// up yet. Failures are logged rather than thrown so Settings can still
    /// tell a configured device from a LAN install.
    func status() async -> TailnetStatusReport? {
        guard let manager else { return nil }
        do {
            return try await manager.status()
        } catch {
            logError(
                "Failed to read tailnet status: \(error.localizedDescription)",
                context: "Tailnet"
            )
            return nil
        }
    }

    /// Joins a phone restoring from a recovery key, which knows the control
    /// plane and the CA's hash but holds neither the CA nor an authorized
    /// device identity yet.
    ///
    /// Joins as the recovery identity, which hsproxy authorizes like any
    /// device, and returns the CA picked from hsproxy's chain so the caller
    /// can pin it. Persists nothing: the caller rejoins with the device
    /// identity once its key is in `pubkeys/`, because hsproxy checks the
    /// identity on every control connection and the recovery key is usually
    /// revoked straight after.
    func joinForRecovery(
        headscaleURL: String,
        caSHA256: String,
        clientIdentity: SecIdentity,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SecCertificate {
        let configuration = try TailnetConfigurationManager.from(headscaleURL: headscaleURL)
        try await join(
            configuration: configuration,
            preauthKey: nil,
            trust: .caSHA256(caSHA256),
            identity: clientIdentity,
            onProgress: onProgress
        )
        guard let ca = await manager?.verifiedCA else {
            throw BootstrapError.missingPinnedCA
        }
        return ca
    }

    private func join(
        configuration: TailnetConfiguration,
        preauthKey: String?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw BootstrapError.missingPinnedCA
        }
        guard let identity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw BootstrapError.missingDeviceIdentity
        }
        try await join(
            configuration: configuration,
            preauthKey: preauthKey,
            trust: .pinned(pinnedCA),
            identity: identity,
            onProgress: onProgress
        )
    }

    private func join(
        configuration: TailnetConfiguration,
        preauthKey: String?,
        trust: HeadscaleControlShim.Trust,
        identity: SecIdentity,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        let manager = self.manager ?? TailnetManager(
            stateDirectory: Self.stateDirectory,
            logger: { message in log(message, context: "Tailnet") }
        )
        self.manager = manager

        try await manager.join(
            TailnetJoinRequest(
                headscaleHost: configuration.headscaleHost,
                headscalePort: configuration.headscalePort,
                preauthKey: preauthKey,
                // The same identifier the deployment already knows this device
                // by, so a tailnet peer list reads the way the device list does
                // rather than showing an unrelated second name.
                hostName: DeviceIdentifierManager.shared.deviceSpaceIdentifier
            ),
            trust: trust,
            clientIdentity: identity,
            onProgress: onProgress
        )

        // Every URLSession the app builds routes through the node's proxy, and
        // the router refuses to hand out a configuration until a node is
        // registered. Registering here rather than at each call site is what
        // keeps a request from silently escaping the tailnet.
        router.use(manager)
        startStatusWatch()
    }

    /// Samples the path to gitd and logs it when it changes.
    ///
    /// A join-time Direct path can become a relay during a long download,
    /// and Settings is not open then, so the log is the only record.
    private func startStatusWatch() {
        statusWatch?.cancel()
        lastLoggedStatus = nil
        lastStatusError = nil
        statusWatch = Task {
            while !Task.isCancelled {
                await logStatusIfChanged()
                do {
                    try await Task.sleep(for: Self.statusPollInterval)
                } catch {
                    break
                }
            }
        }
    }

    /// Writes a new connection summary, and repeats a status failure only
    /// when the error itself changes.
    private func logStatusIfChanged() async {
        guard let manager else { return }
        do {
            let report = try await manager.status()
            lastStatusError = nil
            guard report != lastLoggedStatus else { return }
            lastLoggedStatus = report
            for line in report.logLines {
                log(line, context: "Tailnet")
            }
        } catch {
            let message = error.localizedDescription
            guard message != lastStatusError else { return }
            lastStatusError = message
            lastLoggedStatus = nil
            logError(
                "Failed to read tailnet status: \(message)",
                context: "Tailnet"
            )
        }
    }
}

/// Resumes a waiter with whichever of the join and the timeout finishes
/// first, exactly once.
private final class JoinOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
