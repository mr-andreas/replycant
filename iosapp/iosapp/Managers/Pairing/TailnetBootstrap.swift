import Foundation
import GitDB
import LibGit2
import Security

extension Notification.Name {
    /// Posted when the tailnet node is torn down or comes back, so Settings
    /// does not keep a Connected row for a proxy that no longer exists.
    static let tailnetMembershipDidChange = Notification.Name(
        "replycant.tailnetMembershipDidChange"
    )
}

/// Owns the app's single tailnet node and brings it up when there is one to
/// bring up.
///
/// gitd publishes no host ports, so every request the app makes to it depends
/// on membership. A userspace node only runs while the app
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

    /// A stay shorter than this is a quick app switch. iOS has not had time
    /// to reclaim the node's loopback proxy, so the node is left running.
    static let suspendRebuildThreshold: TimeInterval = 30

    private let configurations: TailnetConfigurationManager
    private let router: TailnetSessionRouter
    private let rejoinOverride: (@Sendable (TailnetConfiguration) async throws -> Void)?
    private let clock: @Sendable () -> Date
    private var manager: TailnetManager?
    private var launchJoin: Task<Void, Error>?
    private var statusWatch: Task<Void, Never>?
    private var lastLoggedStatus: TailnetStatusReport?
    private var lastStatusError: String?
    /// Set when a join has succeeded, including the test stand-in that never
    /// builds a real node. Cleared when the node is torn down for a rebuild.
    private var joined = false
    /// When the app last entered the background, if it has not come back yet.
    private var backgroundedAt: Date?

    /// - Parameter rejoin: replaces the real rejoin, so tests can stand in
    ///   for a node that never comes up.
    /// - Parameter clock: lets tests move the background stay without waiting.
    init(
        configurations: TailnetConfigurationManager = .shared,
        router: TailnetSessionRouter = .shared,
        rejoin: (@Sendable (TailnetConfiguration) async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configurations = configurations
        self.router = router
        self.rejoinOverride = rejoin
        self.clock = clock
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
        if joined { return }
        if let manager, await manager.isJoined {
            joined = true
            return
        }

        let join: Task<Void, Error>
        if let launchJoin {
            join = launchJoin
        } else {
            router.use(nil)
            // Inherits this actor, so it cannot start before `launchJoin` is
            // set, and clearing it afterwards lets a failed join be retried.
            join = Task {
                defer { launchJoin = nil }
                do {
                    try await rejoin(configuration)
                    joined = true
                    notifyMembershipChanged()
                } catch {
                    throw error
                }
            }
            launchJoin = join
        }
        try await Self.wait(for: join, timeout: timeout)
    }

    /// Records that the app left the foreground, so the next return can tell
    /// a quick app switch from a suspend that may have dropped the proxy.
    func noteEnteredBackground() {
        backgroundedAt = clock()
    }

    /// Rebuilds the node after a long background stay.
    ///
    /// The node's status keeps reporting Running across a suspend, because
    /// that read does not use the loopback proxy iOS may have reclaimed.
    /// Rejoining is how a cold launch gets a new proxy and new sockets, so
    /// a long wake does the same thing. A stay under the threshold does
    /// nothing.
    func noteReturnedToForeground() async throws {
        guard let started = backgroundedAt else { return }
        backgroundedAt = nil
        guard clock().timeIntervalSince(started) >= Self.suspendRebuildThreshold else {
            return
        }
        guard let configuration = configurations.load() else { return }
        // A join still coming up is the node we want. Tearing it down would
        // start a second one on the same state directory.
        if launchJoin != nil {
            try await ensureJoinedIfConfigured()
            return
        }
        // Publish the replacement join before the first await. An upload
        // that starts in this window then waits on it, instead of seeing
        // the old node as still joined and dialling a dead proxy.
        joined = false
        let previous = manager
        manager = nil
        router.use(nil)
        statusWatch?.cancel()
        statusWatch = nil
        lastLoggedStatus = nil
        lastStatusError = nil
        notifyMembershipChanged()
        let join = Task {
            defer { launchJoin = nil }
            await previous?.shutDown()
            do {
                try await rejoin(configuration)
                joined = true
                notifyMembershipChanged()
            } catch {
                throw error
            }
        }
        launchJoin = join
        try await Self.wait(for: join, timeout: Self.launchJoinTimeout)
    }

    /// Tells Settings the connection it is showing may no longer exist.
    private func notifyMembershipChanged() {
        let name = Notification.Name.tailnetMembershipDidChange
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
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
        backgroundedAt = nil
        joined = false
        await manager?.shutDown()
        manager = nil
        router.use(nil)
        configurations.clear()
    }

    /// How this device is connected, or nil when there is no node to
    /// describe yet. Failures are logged rather than thrown so Settings still
    /// renders while the node is unreachable.
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
