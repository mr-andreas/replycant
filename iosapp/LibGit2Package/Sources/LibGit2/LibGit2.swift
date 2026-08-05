import Foundation
import Clibgit2
import OSLog

// Network Git operations (push/pull) use mTLS with ECDSA P-256 client certificates via
// a custom libgit2 smart transport registered for the mtls+https:// scheme (ADR-0010).
// See MTLSTransport, ClientIdentityManager, and ServerConfigurationManager for implementation.

// Minimum severity that produces output. Set to "DEBUG" to see routine diagnostics.
internal var logMinLevel: String = "INFO"

private let levelOrder = ["DEBUG": 0, "INFO": 1, "WARNING": 2, "ERROR": 3]

// Accumulates log lines for one capture scope. A reference type so the
// scope can read what nested calls appended.
private final class LogCaptureBuffer {
    var lines: [String] = []
}

private let logCaptureKey = "com.replycant.libgit2.logCapture"

// Collects the log lines the calling thread emits inside `body` instead of
// printing them.
//
// Exists so tests can assert which lines a Git operation produces. Capture is
// scoped to the calling thread rather than the process because the test bundle
// runs suites concurrently: redirecting stdout mixed unrelated suites' output
// into the assertion, which failed these tests for lines they never emitted.
// A thread cannot run two tasks at once, so a synchronous `body` sees only its
// own output.
public func withGitLogCapture<T>(_ body: () throws -> T) rethrows -> (value: T, lines: [String]) {
    let buffer = LogCaptureBuffer()
    let threadDictionary = Thread.current.threadDictionary
    threadDictionary[logCaptureKey] = buffer
    defer { threadDictionary.removeObject(forKey: logCaptureKey) }
    let value = try body()
    return (value, buffer.lines)
}

// Simple logging utility for the LibGit2 package
internal func log(_ message: String, context: String = "Git", level: String = "INFO") {
    guard (levelOrder[level] ?? 1) >= (levelOrder[logMinLevel] ?? 1) else { return }
    let timestamp = timestamp()
    let line = "[\(timestamp)][\(level)][\(context)] \(message)"
    if let buffer = Thread.current.threadDictionary[logCaptureKey] as? LogCaptureBuffer {
        buffer.lines.append(line)
        return
    }
    Swift.print(line)
}

// Returns a timestamp string in format HH:mm:ss.SSS for consistent logging
private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

// Convenience logging functions
internal func logDebug(_ message: String, context: String = "Git") {
    log(message, context: context, level: "DEBUG")
}

internal func logWarning(_ message: String, context: String = "Git") {
    log(message, context: context, level: "WARNING")
}

internal func logError(_ message: String, context: String = "Git") {
    log(message, context: context, level: "ERROR")
}

// Emits signposts for long-running git operations so Instruments can correlate latency with transfer sizes.
private enum GitSignposts {
    private static let logger = Logger(subsystem: "com.replycant.libgit2", category: "PointsOfInterest")
    static let signposter = OSSignposter(logger: logger)

    // Starts one git signposted interval.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    // Ends one git signposted interval without metadata.
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

// Throttles progress updates to avoid overwhelming the UI
private class ProgressThrottler {
    private var lastUpdateTime: Date = Date.distantPast
    private let throttleInterval: TimeInterval = 0.2
    private var lastProgress: GitProgress?
    
    func shouldUpdate() -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateTime)
        if elapsed >= throttleInterval {
            lastUpdateTime = now
            return true
        }
        return false
    }
    
    func update(progress: GitProgress, callback: @escaping (GitProgress) -> Void) {
        lastProgress = progress
        if shouldUpdate() {
            callback(progress)
        }
    }
    
    func flush(callback: @escaping (GitProgress) -> Void) {
        if let progress = lastProgress {
            callback(progress)
        }
    }
}

// Container for progress callback and throttler to pass through libgit2 callbacks
private class ProgressCallbackContainer {
    let callback: (GitProgress) -> Void
    let throttler: ProgressThrottler
    private(set) var lastProgress: GitProgress?
    private var lastTransferProgressLogAt: Date = .distantPast
    
    init(callback: @escaping (GitProgress) -> Void) {
        self.callback = callback
        self.throttler = ProgressThrottler()
    }
    
    func update(progress: GitProgress) {
        lastProgress = progress
        throttler.update(progress: progress, callback: callback)
    }

    // Limits verbose transfer logging so clone progress does not flood logs on fast callbacks.
    func shouldLogTransferProgress() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastTransferProgressLogAt) >= 1.0 {
            lastTransferProgressLogAt = now
            return true
        }
        return false
    }
    
    func flush() {
        throttler.flush(callback: callback)
    }
}

public struct GitProgress {
    // Fetch/transfer phase
    public let receivedObjects: UInt32
    public let totalObjects: UInt32
    public let indexedObjects: UInt32
    public let receivedBytes: UInt64
    
    // Checkout phase
    public let checkoutCompletedSteps: Int
    public let checkoutTotalSteps: Int
    public let currentCheckoutPath: String?
    public let isFetchComplete: Bool
    
    // Combined progress: 50% for fetch, 50% for checkout
    public var percentage: Double {
        let fetchProgress: Double
        if isFetchComplete {
            // Fetch is complete, count it as 50%
            fetchProgress = 50.0
        } else if totalObjects > 0 {
            fetchProgress = Double(receivedObjects) / Double(totalObjects) * 50.0
        } else {
            fetchProgress = 0.0
        }
        
        let checkoutProgress: Double
        if checkoutTotalSteps > 0 {
            checkoutProgress = Double(checkoutCompletedSteps) / Double(checkoutTotalSteps) * 50.0
        } else {
            checkoutProgress = 0.0
        }
        
        return fetchProgress + checkoutProgress
    }
    
    public var description: String {
        let mbReceived = Double(receivedBytes) / 1_000_000.0
        
        if checkoutTotalSteps > 0 && checkoutCompletedSteps > 0 {
            // Show checkout progress
            return String(format: "%.0f%% (Checking out %d/%d files)", 
                         percentage, checkoutCompletedSteps, checkoutTotalSteps)
        } else {
            // Show fetch progress
            return String(format: "%.0f%% (Receiving %d/%d objects, %.1f MB)", 
                         percentage, receivedObjects, totalObjects, mbReceived)
        }
    }
    
    // Helper to create fetch-only progress
    static func fetchProgress(receivedObjects: UInt32, totalObjects: UInt32, indexedObjects: UInt32, receivedBytes: UInt64) -> GitProgress {
        return GitProgress(
            receivedObjects: receivedObjects,
            totalObjects: totalObjects,
            indexedObjects: indexedObjects,
            receivedBytes: receivedBytes,
            checkoutCompletedSteps: 0,
            checkoutTotalSteps: 0,
            currentCheckoutPath: nil,
            isFetchComplete: false
        )
    }
    
    // Helper to create checkout-only progress
    static func checkoutProgress(completedSteps: Int, totalSteps: Int, path: String?, fetchCompleted: Bool = true) -> GitProgress {
        return GitProgress(
            receivedObjects: 0,
            totalObjects: 0,
            indexedObjects: 0,
            receivedBytes: 0,
            checkoutCompletedSteps: completedSteps,
            checkoutTotalSteps: totalSteps,
            currentCheckoutPath: path,
            isFetchComplete: fetchCompleted
        )
    }
}

public enum GitError: Error, LocalizedError {
    case initializationFailed
    case repositoryError(String)
    case authenticationFailed(String)
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize libgit2"
        case .repositoryError(let msg):
            return msg
        case .authenticationFailed(let msg):
            return msg
        case .unknown(let msg):
            return msg
        }
    }
    
    static func fromGitError() -> GitError {
        let error = git_error_last()
        if let error = error, let message = error.pointee.message {
            let errorMessage = String(cString: message)
            return .unknown(errorMessage)
        }
        return .unknown("Unknown error")
    }
}

// Describes git object kinds exposed by tree traversal APIs used for manifest diffing.
public enum GitTreeObjectType {
    case blob
    case tree
    case other
}

// Captures one tree entry so callers can diff commit subtrees without direct libgit2 pointers.
public struct GitTreeEntry {
    public let name: String
    public let oid: String
    public let type: GitTreeObjectType
}

// Tracks remote ref-update statuses so push can fail with the server's rejection reason.
private final class PushUpdateStatusPayload {
    var rejectedRef: String?
    var rejectionStatus: String?
}

public final class Git {
    private static var initialized = false
    
    public static func initialize() throws {
        guard !initialized else {
            logDebug("Already initialized")
            return
        }

        log("Initializing libgit2...")
        let result = git_libgit2_init()
        guard result >= 0 else {
            logError("Initialization failed with code \(result)")
            throw GitError.initializationFailed
        }

        initialized = true
        log("Successfully initialized libgit2")
        
        // Check what features are available
        let features = git_libgit2_features()
        logDebug("Available features: \(features)")
        if (UInt32(features) & UInt32(GIT_FEATURE_HTTPS.rawValue)) != 0 {
            logDebug("HTTPS support is available")
        } else {
            logWarning("HTTPS support is NOT available")
        }
    }
    
    public static func shutdown() {
        guard initialized else { return }
        git_libgit2_shutdown()
        initialized = false
    }
    
    public static var version: String {
        var major: Int32 = 0
        var minor: Int32 = 0
        var patch: Int32 = 0
        git_libgit2_version(&major, &minor, &patch)
        return "\(major).\(minor).\(patch)"
    }
}

public final class Repository: @unchecked Sendable {
    var repo: OpaquePointer?
    private let mutationLock = RepositoryMutationLock()
    
    public init(path: String) throws {
        try Git.initialize()
        
        log("Opening repository at \(path)")
        let result = git_repository_open(&repo, path)
        guard result == 0, repo != nil else {
            logError("Failed to open repository at \(path), error code: \(result)")
            throw GitError.repositoryError("Failed to open repository at \(path)")
        }
        log("Successfully opened repository")
    }
    
    public static func exists(at path: String) -> Bool {
        logDebug("Checking if repository exists at \(path)")
        var repo: OpaquePointer?
        let result = git_repository_open(&repo, path)
        let exists = result == 0
        if let repo = repo {
            git_repository_free(repo)
        }
        logDebug("Repository exists: \(exists)")
        return exists
    }

    // Serializes one repository mutation so libgit2 index/tree writes never overlap.
    public func withMutationLock<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await mutationLock.acquire()
        do {
            let result = try await operation()
            await mutationLock.release()
            return result
        } catch {
            await mutationLock.release()
            throw error
        }
    }

    // Attempts one repository mutation without waiting so background sync ticks can skip overlap.
    public func tryWithMutationLock<T>(_ operation: @Sendable () async throws -> T) async throws -> T? {
        let acquired = await mutationLock.tryAcquire()
        guard acquired else {
            return nil
        }
        do {
            let result = try await operation()
            await mutationLock.release()
            return result
        } catch {
            await mutationLock.release()
            throw error
        }
    }
    
    public static func create(at path: String, bare: Bool = false) throws -> Repository {
        try Git.initialize()
        
        log("Creating repository at \(path), bare: \(bare)")
        var repo: OpaquePointer?
        
        // Initialize repository options
        var options = git_repository_init_options()
        let optionsResult = git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        guard optionsResult == 0 else {
            log("Failed to initialize repository options, error code: \(optionsResult)")
            throw GitError.repositoryError("Failed to initialize repository options")
        }
        
        // Set initial branch to "main"
        let initialHead = strdup("main")
        options.initial_head = UnsafePointer(initialHead)
        defer {
            if let head = initialHead {
                free(head)
            }
        }
        
        // Set flags: always create path, and optionally set bare
        options.flags = UInt32(GIT_REPOSITORY_INIT_MKPATH.rawValue)
        if bare {
            options.flags |= UInt32(GIT_REPOSITORY_INIT_BARE.rawValue)
        }
        
        // Create repository with extended options
        let result = git_repository_init_ext(&repo, path, &options)
        guard result == 0, let repository = repo else {
            log("Failed to create repository at \(path), error code: \(result)")
            let error = GitError.fromGitError()
            log("Error details: \(error)")
            throw GitError.repositoryError("Failed to create repository at \(path): \(error)")
        }
        
        log("Successfully created repository with initial branch 'main'")
        let instance = Repository(internalRepo: repository)
        return instance
    }
    
    // Supports initial and recovery sync flows by allowing shallow clone depth to reduce memory and bandwidth on large repositories.
    public static func clone(from url: String, to path: String, depth: Int32? = nil, progressCallback: ((GitProgress) -> Void)? = nil) throws -> Repository {
        try Git.initialize()
        let cloneSignpost = GitSignposts.begin("GitClone")
        var cloneSucceeded = false
        var cloneReceivedObjects: UInt32 = 0
        var cloneTotalObjects: UInt32 = 0
        var cloneReceivedBytes: UInt64 = 0
        defer {
            if cloneSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitClone",
                    cloneSignpost,
                    "receivedObjects=\(cloneReceivedObjects, privacy: .public) totalObjects=\(cloneTotalObjects, privacy: .public) receivedBytes=\(cloneReceivedBytes, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitClone", cloneSignpost)
            }
        }
        
        log("Cloning repository from \(url) to \(path)")
        let startTime = Date()
        
        var cloneOptions = git_clone_options()
        let cloneOptionsResult = git_clone_options_init(&cloneOptions, UInt32(GIT_CLONE_OPTIONS_VERSION))
        guard cloneOptionsResult == 0 else {
            log("Failed to initialize clone options, error code: \(cloneOptionsResult)")
            throw GitError.repositoryError("Failed to initialize clone options")
        }
        
        cloneOptions.fetch_opts.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL
        cloneOptions.checkout_opts.checkout_strategy = UInt32(GIT_CHECKOUT_NONE.rawValue)
        if let depth {
            cloneOptions.fetch_opts.depth = depth
        }
        
        var callbacks = git_remote_callbacks()
        let callbacksResult = git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        log("Initialized callbacks, result: \(callbacksResult)")
        
        // Create a container with throttling for progress updates
        let container = ProgressCallbackContainer(callback: progressCallback ?? { _ in })
        let payload = Unmanaged.passUnretained(container).toOpaque()
        
        callbacks.transfer_progress = { (stats, payload) -> Int32 in
            guard let stats = stats, let payload = payload else { return 0 }
            
            let container = Unmanaged<ProgressCallbackContainer>.fromOpaque(payload).takeUnretainedValue()
            
            let progress = GitProgress.fetchProgress(
                receivedObjects: stats.pointee.received_objects,
                totalObjects: stats.pointee.total_objects,
                indexedObjects: stats.pointee.indexed_objects,
                receivedBytes: UInt64(stats.pointee.received_bytes)
            )
            
            if container.shouldLogTransferProgress() {
                log("CLONE transfer progress: \(stats.pointee.received_objects)/\(stats.pointee.total_objects) objects", context: "Git")
            }
            container.update(progress: progress)
            return 0
        }
        
        cloneOptions.fetch_opts.callbacks = callbacks
        cloneOptions.fetch_opts.callbacks.payload = payload
        
        var repo: OpaquePointer?
        let result = git_clone(&repo, url, path, &cloneOptions)
        guard result == 0, let repository = repo else {
            log("Failed to clone repository, error code: \(result)")
            let error = GitError.fromGitError()
            log("Error details: \(error)")
            throw error
        }
        
        // Flush any pending progress updates
        container.flush()
        if let progress = container.lastProgress {
            cloneReceivedObjects = progress.receivedObjects
            cloneTotalObjects = progress.totalObjects
            cloneReceivedBytes = progress.receivedBytes
        }
        
        let duration = Date().timeIntervalSince(startTime)
        log("Successfully cloned repository in \(String(format: "%.2f", duration))s")
        let instance = Repository(internalRepo: repository)
        
        // Configure upstream tracking for the default branch
        do {
            if let branchName = instance.currentBranch() {
                try instance.setUpstreamBranch(localBranch: branchName, remoteName: "origin", remoteBranch: branchName)
            }
        } catch {
            log("Warning - Failed to set upstream tracking after clone: \(error.localizedDescription)")
            // Don't fail the clone if upstream tracking configuration fails
        }
        
        cloneSucceeded = true
        return instance
    }
    
    private init(internalRepo repo: OpaquePointer) {
        self.repo = repo
    }
    
    deinit {
        if let repo = repo {
            git_repository_free(repo)
        }
    }
    
    public var path: String? {
        guard let repo = repo else { return nil }
        guard let cPath = git_repository_path(repo) else { return nil }
        return String(cString: cPath)
    }
    
    public var workdir: String? {
        guard let repo = repo else { return nil }
        guard let cPath = git_repository_workdir(repo) else { return nil }
        return String(cString: cPath)
    }
    
    public var isBare: Bool {
        guard let repo = repo else { return false }
        return git_repository_is_bare(repo) != 0
    }
    
    public func createCommit(message: String, files: [(path: String, content: String)]) throws {
        let commitSignpost = GitSignposts.begin("GitCreateCommit")
        var commitSucceeded = false
        defer {
            if commitSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitCreateCommit",
                    commitSignpost,
                    "files=\(files.count, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitCreateCommit", commitSignpost)
            }
        }
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        logDebug("Creating commit with message: '\(message)'")
        logDebug("Files to commit: \(files.map { $0.path })")
        
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let idx = index else {
            logDebug("Failed to get repository index")
            throw GitError.repositoryError("Failed to get repository index")
        }
        defer { git_index_free(idx) }
        logDebug("Got repository index")

        // Keep existing tracked files in the next tree when cloning with checkout disabled.
        try syncIndexFromHead(index: idx)
        
        for file in files {
            let contentData = Data(file.content.utf8)
            let addResult = file.path.withCString { cPath -> Int32 in
                var entry = git_index_entry()
                entry.mode = UInt32(GIT_FILEMODE_BLOB.rawValue)
                entry.path = cPath
                return contentData.withUnsafeBytes { bytes -> Int32 in
                    git_index_add_frombuffer(idx, &entry, bytes.baseAddress, bytes.count)
                }
            }
            guard addResult == 0 else {
                logDebug("Failed to add file \(file.path) from memory, error code: \(addResult)")
                let error = GitError.fromGitError()
                throw GitError.repositoryError("Failed to add file to index: \(error)")
            }
            logDebug("Added \(file.path) to index from memory")
        }
        
        guard git_index_write(idx) == 0 else {
            logDebug("Failed to write index")
            throw GitError.repositoryError("Failed to write index")
        }
        logDebug("Wrote index")
        
        var treeOid = git_oid()
        guard git_index_write_tree(&treeOid, idx) == 0 else {
            logDebug("Failed to write tree")
            throw GitError.repositoryError("Failed to write tree")
        }
        logDebug("Wrote tree")
        
        var tree: OpaquePointer?
        guard git_tree_lookup(&tree, repo, &treeOid) == 0, let commitTree = tree else {
            logDebug("Failed to lookup tree")
            throw GitError.repositoryError("Failed to lookup tree")
        }
        defer { git_tree_free(commitTree) }
        logDebug("Looked up tree")
        
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            logDebug("Creating custom signature")
            guard git_signature_now(&sig, "iOS User", "user@ios.app") == 0 else {
                logDebug("Failed to create signature")
                throw GitError.repositoryError("Failed to create signature")
            }
        } else {
            logDebug("Using default signature")
        }
        guard let signature = sig else {
            logDebug("No signature available")
            throw GitError.repositoryError("Failed to create signature")
        }
        defer { git_signature_free(signature) }
        
        var parentCommit: OpaquePointer?
        let hasParent = git_reference_name_to_id(&treeOid, repo, "HEAD") == 0 &&
                        git_commit_lookup(&parentCommit, repo, &treeOid) == 0
        logDebug("Has parent commit: \(hasParent)")
        
        var commitOid = git_oid()
        let result: Int32
        if hasParent, let parent = parentCommit {
            defer { git_commit_free(parent) }
            var parents: [OpaquePointer?] = [parent]
            logDebug("Creating commit with parent")
            result = parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, message, commitTree, 1, buffer.baseAddress)
            }
        } else {
            logDebug("Creating initial commit")
            result = git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, message, commitTree, 0, nil)
        }
        
        guard result == 0 else {
            logDebug("Failed to create commit, error code: \(result)")
            throw GitError.repositoryError("Failed to create commit")
        }
        logDebug("Successfully created commit")
        commitSucceeded = true
    }
    
    // Sets the remote URL without validation.
    // Accepts any URL format including custom schemes (e.g., mtld+https://).
    public func addRemote(name: String, url: String) throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        log("Setting remote '\(name)' URL to '\(url)'")
        
        var remote: OpaquePointer?
        let result = git_remote_create(&remote, repo, name, url)
        
        if result != 0 {
            if result == Int32(GIT_EEXISTS.rawValue) {
                log("Remote '\(name)' already exists, updating URL")
                guard git_remote_set_url(repo, name, url) == 0 else {
                    log("Failed to update remote URL")
                    throw GitError.repositoryError("Failed to update remote URL")
                }
                log("Successfully updated remote URL to '\(url)'")
            } else {
                log("Failed to create remote, error code: \(result)")
                let error = GitError.fromGitError()
                throw GitError.repositoryError("Failed to create remote: \(error)")
            }
        } else {
            log("Successfully created remote '\(name)' with URL '\(url)'")
        }
        
        if let remote = remote {
            git_remote_free(remote)
        }
    }
    
    public func hasRemote(name: String = "origin") -> Bool {
        guard let repo = repo else {
            log("Repository not initialized")
            return false
        }
        
        log("Checking if remote '\(name)' exists")
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo, name)
        let exists = lookupResult == 0
        if let remote = remote {
            git_remote_free(remote)
        }
        log("Remote '\(name)' exists: \(exists)")
        return exists
    }
    
    public func getRemoteUrl(name: String = "origin") -> String? {
        guard let repo = repo else {
            log("Repository not initialized")
            return nil
        }
        
        log("Getting URL for remote '\(name)'")
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo, name)
        guard lookupResult == 0, let gitRemote = remote else {
            log("Failed to lookup remote '\(name)', error code: \(lookupResult)")
            return nil
        }
        defer { git_remote_free(gitRemote) }
        
        guard let url = git_remote_url(gitRemote) else {
            log("No URL found for remote '\(name)'")
            return nil
        }
        
        let urlString = String(cString: url)
        log("Remote '\(name)' URL: \(urlString)")
        return urlString
    }
    
    public func currentBranch() -> String? {
        guard let repo = repo else {
            log("Repository not initialized")
            return nil
        }
        
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0, let headRef = head else {
            log("Failed to get HEAD reference")
            return nil
        }
        defer { git_reference_free(headRef) }
        
        guard let refName = git_reference_name(headRef) else {
            log("Failed to get reference name")
            return nil
        }
        
        let fullName = String(cString: refName)
        logDebug("HEAD reference: \(fullName)")
        
        // Extract branch name from refs/heads/branch_name
        if fullName.hasPrefix("refs/heads/") {
            let branchName = String(fullName.dropFirst("refs/heads/".count))
            logDebug("Current branch: \(branchName)")
            return branchName
        }
        
        return nil
    }
    
    // Configures a local branch to track a remote branch.
    // This enables git status to show ahead/behind comparisons with the remote.
    public func setUpstreamBranch(localBranch: String, remoteName: String, remoteBranch: String) throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        let upstreamName = "\(remoteName)/\(remoteBranch)"
        logDebug("Setting upstream for '\(localBranch)' to '\(upstreamName)'")
        
        // Get the local branch reference
        var branchRef: OpaquePointer?
        let refName = "refs/heads/\(localBranch)"
        let lookupResult = git_reference_lookup(&branchRef, repo, refName)
        guard lookupResult == 0, let branch = branchRef else {
            log("Failed to lookup branch '\(localBranch)', error code: \(lookupResult)")
            throw GitError.repositoryError("Failed to lookup branch: \(localBranch)")
        }
        defer { git_reference_free(branch) }
        
        // Set the upstream branch
        let result = git_branch_set_upstream(branch, upstreamName)
        guard result == 0 else {
            log("Failed to set upstream, error code: \(result)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to set upstream: \(error)")
        }
        
        logDebug("Successfully set upstream for '\(localBranch)' to '\(upstreamName)'")
    }
    
    // Fetches from a remote to update remote-tracking refs without modifying the working directory.
    // This updates the ahead/behind information shown by git status.
    public func fetch(remoteName: String = "origin") throws {
        let fetchSignpost = GitSignposts.begin("GitFetch")
        var fetchSucceeded = false
        var fetchedTotalObjects: UInt32 = 0
        var fetchedReceivedObjects: UInt32 = 0
        var fetchedReceivedBytes: UInt64 = 0
        defer {
            if fetchSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitFetch",
                    fetchSignpost,
                    "totalObjects=\(fetchedTotalObjects, privacy: .public) receivedObjects=\(fetchedReceivedObjects, privacy: .public) receivedBytes=\(fetchedReceivedBytes, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitFetch", fetchSignpost)
            }
        }
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        log("Fetching from remote '\(remoteName)'")
        
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo, remoteName)
        guard lookupResult == 0, let gitRemote = remote else {
            log("Failed to lookup remote '\(remoteName)', error code: \(lookupResult)")
            throw GitError.repositoryError("Failed to lookup remote: \(remoteName)")
        }
        defer { git_remote_free(gitRemote) }
        
        if let url = git_remote_url(gitRemote) {
            let urlString = String(cString: url)
            log("Fetching from URL: \(urlString)")
        }
        
        var callbacks = git_remote_callbacks()
        let callbacksResult = git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        log("Initialized callbacks, result: \(callbacksResult)")
        
        var fetchOptions = git_fetch_options()
        let fetchOptionsResult = git_fetch_options_init(&fetchOptions, UInt32(GIT_FETCH_OPTIONS_VERSION))
        log("Initialized fetch options, result: \(fetchOptionsResult)")
        fetchOptions.callbacks = callbacks
        fetchOptions.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL
        
        log("Starting fetch operation...")
        let startTime = Date()
        let fetchResult = git_remote_fetch(gitRemote, nil, &fetchOptions, nil)
        let duration = Date().timeIntervalSince(startTime)
        log("Fetch operation completed with result: \(fetchResult) in \(String(format: "%.2f", duration))s")
        
        guard fetchResult == 0 else {
            log("Fetch failed with error code: \(fetchResult)")
            let error = GitError.fromGitError()
            log("Error details: \(error)")
            throw GitError.repositoryError("Failed to fetch from remote: \(error)")
        }
        if let stats = git_remote_stats(gitRemote) {
            fetchedTotalObjects = stats.pointee.total_objects
            fetchedReceivedObjects = stats.pointee.received_objects
            fetchedReceivedBytes = UInt64(stats.pointee.received_bytes)
        }
        
        log("Successfully fetched from remote")
        fetchSucceeded = true
    }
    
    // Pushes branch updates to a remote and skips network work when remote tracking is already up to date.
    public func push(remoteName: String = "origin", branchName: String? = nil) throws {
        let pushSignpost = GitSignposts.begin("GitPush")
        var pushSucceeded = false
        var signpostedBranch = "unknown"
        guard let repo = repo else {
            GitSignposts.end("GitPush", pushSignpost)
            throw GitError.repositoryError("Repository not initialized")
        }
        defer {
            if pushSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitPush",
                    pushSignpost,
                    "branch=\(signpostedBranch, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitPush", pushSignpost)
            }
        }
        
        // Detect current branch if not specified
        let actualBranch: String
        if let specifiedBranch = branchName {
            actualBranch = specifiedBranch
        } else if let detectedBranch = currentBranch() {
            actualBranch = detectedBranch
            logDebug("Auto-detected current branch: \(actualBranch)")
        } else {
            throw GitError.repositoryError("No branch specified and could not detect current branch")
        }
        signpostedBranch = actualBranch
        
        logDebug("Starting push to remote '\(remoteName)', branch '\(actualBranch)'")

        var localBranchOid = git_oid()
        let localBranchRef = "refs/heads/\(actualBranch)"
        let localBranchResult = git_reference_name_to_id(&localBranchOid, repo, localBranchRef)
        if localBranchResult == 0 {
            var remoteTrackingOid = git_oid()
            let remoteTrackingRef = "refs/remotes/\(remoteName)/\(actualBranch)"
            let remoteTrackingResult = git_reference_name_to_id(&remoteTrackingOid, repo, remoteTrackingRef)
            if remoteTrackingResult == 0 && git_oid_equal(&localBranchOid, &remoteTrackingOid) != 0 {
                logDebug("Nothing to push - local \(actualBranch) matches \(remoteTrackingRef)")
                pushSucceeded = true
                return
            }
        }
        
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo, remoteName)
        guard lookupResult == 0, let gitRemote = remote else {
            log("Failed to lookup remote '\(remoteName)', error code: \(lookupResult)")
            throw GitError.repositoryError("Failed to lookup remote: \(remoteName)")
        }
        defer { git_remote_free(gitRemote) }
        logDebug("Successfully looked up remote '\(remoteName)'")
        
        // Get remote URL for logging
        if let url = git_remote_url(gitRemote) {
            let urlString = String(cString: url)
            logDebug("Remote URL: \(urlString)")
        }
        
        var callbacks = git_remote_callbacks()
        let callbacksResult = git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        logDebug("Initialized callbacks, result: \(callbacksResult)")
        let pushStatusPayload = PushUpdateStatusPayload()
        let pushStatusPayloadPtr = Unmanaged.passRetained(pushStatusPayload)
        defer { pushStatusPayloadPtr.release() }
        
        callbacks.push_update_reference = { (refname, status, payload) -> Int32 in
            guard let payload else {
                return 0
            }
            let statusPayload = Unmanaged<PushUpdateStatusPayload>.fromOpaque(payload).takeUnretainedValue()
            let remoteRef = refname.map { String(cString: $0) } ?? "unknown ref"
            guard let status else {
                logDebug("Remote accepted update for \(remoteRef)")
                return 0
            }
            let statusMessage = String(cString: status)
            statusPayload.rejectedRef = remoteRef
            statusPayload.rejectionStatus = statusMessage
            logError("Remote rejected update for \(remoteRef): \(statusMessage)")
            return -1
        }
        callbacks.payload = pushStatusPayloadPtr.toOpaque()
        
        var pushOptions = git_push_options()
        let pushOptionsResult = git_push_options_init(&pushOptions, UInt32(GIT_PUSH_OPTIONS_VERSION))
        logDebug("Initialized push options, result: \(pushOptionsResult)")
        pushOptions.callbacks = callbacks
        pushOptions.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL
        
        let refspec = "refs/heads/\(actualBranch):refs/heads/\(actualBranch)"
        logDebug("Using refspec: \(refspec)")
        var refspecs = git_strarray()
        let refspecPtr = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: 1)
        refspecPtr[0] = strdup(refspec)
        refspecs.strings = UnsafeMutablePointer(mutating: UnsafePointer(refspecPtr))
        refspecs.count = 1
        
        defer {
            if let ptr = refspecPtr[0] {
                free(ptr)
            }
            refspecPtr.deallocate()
        }
        
        logDebug("Starting push operation...")
        let startTime = Date()
        let pushResult = git_remote_push(gitRemote, &refspecs, &pushOptions)
        let duration = Date().timeIntervalSince(startTime)
        logDebug("Push operation completed with result: \(pushResult) in \(String(format: "%.2f", duration))s")
        if let rejectedRef = pushStatusPayload.rejectedRef,
           let rejectionStatus = pushStatusPayload.rejectionStatus {
            throw GitError.repositoryError("Remote rejected \(rejectedRef): \(rejectionStatus)")
        }
        
        guard pushResult == 0 else {
            log("Push failed with error code: \(pushResult)")
            let error = GitError.fromGitError()
            log("Error details: \(error)")
            
            // Additional error information
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                log("Last error message: \(errorMessage)")
            }
            
            // Check if it's a network/connection issue
            if pushResult == Int32(GIT_EEXISTS.rawValue) {
                log("Remote already exists (this might be expected)")
            } else if pushResult == Int32(GIT_ENOTFOUND.rawValue) {
                log("Remote not found")
            } else if pushResult == Int32(GIT_EINVALIDSPEC.rawValue) {
                log("Invalid refspec")
            } else if pushResult == Int32(GIT_EAUTH.rawValue) {
                log("Authentication failed")
            } else {
                log("Other error (code: \(pushResult))")
            }
            
            throw GitError.repositoryError("Failed to push to remote: \(error)")
        }
        log("Successfully pushed to remote")
        
        // Configure upstream tracking branch so git status can show ahead/behind comparisons
        do {
            try setUpstreamBranch(localBranch: actualBranch, remoteName: remoteName, remoteBranch: actualBranch)
        } catch {
            log("Warning - Failed to set upstream tracking: \(error.localizedDescription)")
            // Don't fail the push if upstream tracking configuration fails
        }
        pushSucceeded = true
    }
    
    // Pulls remote changes while preserving local commits, and bootstraps empty local branches by fast-forwarding.
    public func pullRebase(remoteName: String = "origin", branchName: String? = nil, progressCallback: ((GitProgress) -> Void)? = nil) throws {
        let pullSignpost = GitSignposts.begin("GitPullRebase")
        var pullSucceeded = false
        var fetchedTotalObjects: UInt32 = 0
        var fetchedReceivedObjects: UInt32 = 0
        var fetchedReceivedBytes: UInt64 = 0
        var rebaseOperationCount: Int = 0
        defer {
            if pullSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitPullRebase",
                    pullSignpost,
                    "totalObjects=\(fetchedTotalObjects, privacy: .public) receivedObjects=\(fetchedReceivedObjects, privacy: .public) receivedBytes=\(fetchedReceivedBytes, privacy: .public) rebaseOps=\(rebaseOperationCount, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitPullRebase", pullSignpost)
            }
        }
        guard let repo = repo else {
            log("REBASE ERROR - Repository not initialized")
            throw GitError.repositoryError("Repository not initialized")
        }
        
        let actualBranch: String
        if let specifiedBranch = branchName {
            actualBranch = specifiedBranch
            logDebug("REBASE - Using specified branch: \(actualBranch)")
        } else if let detectedBranch = currentBranch() {
            actualBranch = detectedBranch
            logDebug("REBASE - Auto-detected current branch: \(actualBranch)")
        } else {
            log("REBASE ERROR - No branch specified and could not detect current branch")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                log("REBASE ERROR - Last git error: \(errorMessage)")
            }
            throw GitError.repositoryError("No branch specified and could not detect current branch")
        }
        
        logDebug("REBASE - Starting pull with rebase from remote '\(remoteName)', branch '\(actualBranch)'")
        
        var headOid = git_oid()
        let hasLocalHead = git_reference_name_to_id(&headOid, repo, "HEAD") == 0
        if hasLocalHead {
            var oidStr = [Int8](repeating: 0, count: 41)
            git_oid_tostr(&oidStr, 41, &headOid)
            let headSha = String(cString: oidStr)
            logDebug("REBASE - Current HEAD: \(headSha)")
        } else {
            log("REBASE - Local branch has no commits yet; will fast-forward after fetch")
        }
        
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo, remoteName)
        guard lookupResult == 0, let gitRemote = remote else {
            log("REBASE ERROR - Failed to lookup remote '\(remoteName)', error code: \(lookupResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                log("REBASE ERROR - Last git error: \(errorMessage)")
            }
            throw GitError.repositoryError("Failed to lookup remote: \(remoteName)")
        }
        defer { git_remote_free(gitRemote) }
        logDebug("REBASE - Successfully looked up remote '\(remoteName)'")
        
        if let url = git_remote_url(gitRemote) {
            let urlString = String(cString: url)
            logDebug("REBASE - Remote URL: \(urlString)")
        }
        
        var callbacks = git_remote_callbacks()
        let callbacksResult = git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        logDebug("REBASE - Initialized callbacks, result: \(callbacksResult)")
        
        // Create a container with throttling for progress updates
        let container = progressCallback.map { ProgressCallbackContainer(callback: $0) }
        let payload = container.map { Unmanaged.passUnretained($0).toOpaque() } ?? nil
        
        callbacks.transfer_progress = { (stats, payload) -> Int32 in
            guard let stats = stats, let payload = payload else { return 0 }
            
            let container = Unmanaged<ProgressCallbackContainer>.fromOpaque(payload).takeUnretainedValue()
            
            let progress = GitProgress.fetchProgress(
                receivedObjects: stats.pointee.received_objects,
                totalObjects: stats.pointee.total_objects,
                indexedObjects: stats.pointee.indexed_objects,
                receivedBytes: UInt64(stats.pointee.received_bytes)
            )
            
            container.update(progress: progress)
            return 0
        }
        
        var fetchOptions = git_fetch_options()
        let fetchOptionsResult = git_fetch_options_init(&fetchOptions, UInt32(GIT_FETCH_OPTIONS_VERSION))
        logDebug("REBASE - Initialized fetch options, result: \(fetchOptionsResult)")
        fetchOptions.callbacks = callbacks
        fetchOptions.callbacks.payload = payload
        fetchOptions.follow_redirects = GIT_REMOTE_REDIRECT_INITIAL
        
        logDebug("REBASE - Starting fetch operation...")
        let startTime = Date()
        let fetchResult = git_remote_fetch(gitRemote, nil, &fetchOptions, nil)
        let fetchDuration = Date().timeIntervalSince(startTime)
        logDebug("REBASE - Fetch operation completed with result: \(fetchResult) in \(String(format: "%.2f", fetchDuration))s")
        
        guard fetchResult == 0 else {
            log("REBASE ERROR - Fetch failed with error code: \(fetchResult)")
            let error = GitError.fromGitError()
            log("REBASE ERROR - Error details: \(error)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to fetch from remote: \(error)")
        }
        if let stats = git_remote_stats(gitRemote) {
            fetchedTotalObjects = stats.pointee.total_objects
            fetchedReceivedObjects = stats.pointee.received_objects
            fetchedReceivedBytes = UInt64(stats.pointee.received_bytes)
        }
        logDebug("REBASE - Successfully fetched from remote")
        
        var upstreamOid = git_oid()
        let upstreamRef = "refs/remotes/\(remoteName)/\(actualBranch)"
        logDebug("REBASE - Looking up upstream ref: \(upstreamRef)")
        let refLookupResult = git_reference_name_to_id(&upstreamOid, repo, upstreamRef)
        guard refLookupResult == 0 else {
            log("REBASE ERROR - Failed to find upstream branch '\(upstreamRef)', error code: \(refLookupResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to find upstream branch: \(upstreamRef)")
        }
        var upstreamOidStr = [Int8](repeating: 0, count: 41)
        git_oid_tostr(&upstreamOidStr, 41, &upstreamOid)
        let upstreamSha = String(cString: upstreamOidStr)
        logDebug("REBASE - Found upstream branch '\(upstreamRef)' at commit \(upstreamSha)")

        if !hasLocalHead {
            log("REBASE - No local HEAD commit found, fast-forwarding branch '\(actualBranch)' to upstream")
            try fastForward(toOID: upstreamSha, branchName: actualBranch)

            do {
                try setUpstreamBranch(localBranch: actualBranch, remoteName: remoteName, remoteBranch: actualBranch)
            } catch {
                log("REBASE - Warning - Failed to set upstream tracking after bootstrap fast-forward: \(error.localizedDescription)")
            }

            container?.flush()
            let totalDuration = Date().timeIntervalSince(startTime)
            log("REBASE - Successfully bootstrapped local branch from upstream in \(String(format: "%.2f", totalDuration))s")
            pullSucceeded = true
            return
        }
        
        // Check if we're already up to date (HEAD == upstream)
        if git_oid_equal(&headOid, &upstreamOid) != 0 {
            logDebug("REBASE - Already up to date, skipping rebase")
            
            // Flush any pending progress updates
            container?.flush()
            
            // Still set upstream tracking branch for git status
            do {
                try setUpstreamBranch(localBranch: actualBranch, remoteName: remoteName, remoteBranch: actualBranch)
            } catch {
                log("REBASE - Warning - Failed to set upstream tracking: \(error.localizedDescription)")
            }
            
            let totalDuration = Date().timeIntervalSince(startTime)
            logDebug("REBASE - Successfully completed pull with rebase in \(String(format: "%.2f", totalDuration))s")
            pullSucceeded = true
            return
        }

        // Skip rebase when local has no unique commits and can move directly to upstream.
        let upstreamDescendsFromHead = git_graph_descendant_of(repo, &upstreamOid, &headOid)
        if upstreamDescendsFromHead == 1 {
            log("REBASE - Upstream is ahead with no local divergence, fast-forwarding local branch")
            try fastForward(toOID: upstreamSha, branchName: actualBranch)

            do {
                try setUpstreamBranch(localBranch: actualBranch, remoteName: remoteName, remoteBranch: actualBranch)
            } catch {
                log("REBASE - Warning - Failed to set upstream tracking after fast-forward: \(error.localizedDescription)")
            }

            container?.flush()
            let totalDuration = Date().timeIntervalSince(startTime)
            log("REBASE - Successfully completed pull via fast-forward in \(String(format: "%.2f", totalDuration))s")
            pullSucceeded = true
            return
        }
        if upstreamDescendsFromHead < 0 {
            log("REBASE - Warning - Failed to compute ancestry for fast-forward check; falling back to rebase path")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE - Warning - Last git error: \(errorMessage) (class: \(errorClass))")
            }
        }
        
        log("REBASE - HEAD differs from upstream, proceeding with rebase")

        var upstreamCommit: OpaquePointer?
        let commitLookupResult = git_commit_lookup(&upstreamCommit, repo, &upstreamOid)
        guard commitLookupResult == 0, let upstream = upstreamCommit else {
            log("REBASE ERROR - Failed to lookup upstream commit, error code: \(commitLookupResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to lookup upstream commit")
        }
        defer { git_commit_free(upstream) }
        logDebug("REBASE - Successfully looked up upstream commit")
        
        var annotatedUpstream: OpaquePointer?
        let annotatedResult = git_annotated_commit_lookup(&annotatedUpstream, repo, &upstreamOid)
        guard annotatedResult == 0, let annotated = annotatedUpstream else {
            log("REBASE ERROR - Failed to create annotated commit, error code: \(annotatedResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to create annotated commit")
        }
        defer { git_annotated_commit_free(annotated) }
        logDebug("REBASE - Created annotated commit for rebase")
        
        // Initialize rebase options with checkout progress callback
        var rebaseOptions = git_rebase_options()
        let rebaseOptionsResult = git_rebase_options_init(&rebaseOptions, UInt32(GIT_REBASE_OPTIONS_VERSION))
        guard rebaseOptionsResult == 0 else {
            log("REBASE ERROR - Failed to initialize rebase options, error code: \(rebaseOptionsResult)")
            throw GitError.repositoryError("Failed to initialize rebase options")
        }
        
        rebaseOptions.inmemory = 1
        
        var rebase: OpaquePointer?
        logDebug("REBASE - Initializing rebase operation...")
        let rebaseResult = git_rebase_init(&rebase, repo, nil, annotated, nil, &rebaseOptions)
        guard rebaseResult == 0, let gitRebase = rebase else {
            log("REBASE ERROR - Failed to initialize rebase, error code: \(rebaseResult)")
            let error = GitError.fromGitError()
            log("REBASE ERROR - Error details: \(error)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to initialize rebase: \(error)")
        }
        defer { git_rebase_free(gitRebase) }
        
        let opCount = git_rebase_operation_entrycount(gitRebase)
        rebaseOperationCount = Int(opCount)
        log("REBASE - Initialized rebase with \(opCount) operations to apply")
        
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            logDebug("REBASE - Creating custom signature")
            guard git_signature_now(&sig, "iOS User", "user@ios.app") == 0 else {
                log("REBASE ERROR - Failed to create signature")
                throw GitError.repositoryError("Failed to create signature")
            }
        } else {
            logDebug("REBASE - Using default signature")
        }
        guard let signature = sig else {
            log("REBASE ERROR - No signature available")
            throw GitError.repositoryError("Failed to create signature")
        }
        defer { git_signature_free(signature) }
        logDebug("REBASE - Created signature for rebase commits")
        
        var operation: UnsafeMutablePointer<git_rebase_operation>?
        var opIndex = 0
        var hasRebasedCommit = false
        var lastRebasedCommitOid = git_oid()
        var nextResult = git_rebase_next(&operation, gitRebase)
        
        while nextResult == 0 {
            opIndex += 1
            logDebug("REBASE - Applying operation \(opIndex)/\(opCount)...")
            
            if let op = operation?.pointee {
                var opOid = op.id
                var opOidStr = [Int8](repeating: 0, count: 41)
                git_oid_tostr(&opOidStr, 41, &opOid)
                let opSha = String(cString: opOidStr)
                logDebug("REBASE - Operation type: \(op.type.rawValue), commit: \(opSha)")
            }
            
            var newCommitOid = git_oid()
            let commitResult = git_rebase_commit(&newCommitOid, gitRebase, nil, signature, nil, nil)
            if commitResult != 0 {
                log("REBASE ERROR - Failed to commit during rebase, error code: \(commitResult)")
                if let lastError = git_error_last() {
                    let errorMessage = String(cString: lastError.pointee.message)
                    let errorClass = lastError.pointee.klass
                    log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
                }
                logDebug("REBASE - Aborting rebase due to error")
                git_rebase_abort(gitRebase)
                throw GitError.repositoryError("Failed to apply rebase operation")
            }
            hasRebasedCommit = true
            lastRebasedCommitOid = newCommitOid
            
            var newOidStr = [Int8](repeating: 0, count: 41)
            git_oid_tostr(&newOidStr, 41, &newCommitOid)
            let newSha = String(cString: newOidStr)
            logDebug("REBASE - Successfully applied operation, new commit: \(newSha)")
            
            nextResult = git_rebase_next(&operation, gitRebase)
        }
        
        if nextResult != Int32(GIT_ITEROVER.rawValue) {
            log("REBASE ERROR - Unexpected result from git_rebase_next: \(nextResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
        } else {
            log("REBASE - All operations applied successfully")
        }
        
        logDebug("REBASE - Finishing rebase...")
        let finishResult = git_rebase_finish(gitRebase, signature)
        guard finishResult == 0 else {
            log("REBASE ERROR - Failed to finish rebase, error code: \(finishResult)")
            if let lastError = git_error_last() {
                let errorMessage = String(cString: lastError.pointee.message)
                let errorClass = lastError.pointee.klass
                log("REBASE ERROR - Last git error: \(errorMessage) (class: \(errorClass))")
            }
            throw GitError.repositoryError("Failed to finish rebase")
        }
        
        var targetOid = hasRebasedCommit ? lastRebasedCommitOid : upstreamOid
        var targetOidStr = [Int8](repeating: 0, count: 41)
        git_oid_tostr(&targetOidStr, 41, &targetOid)
        let targetSha = String(cString: targetOidStr)
        log("REBASE - Updating local branch '\(actualBranch)' to \(targetSha) after in-memory rebase")
        try fastForward(toOID: targetSha, branchName: actualBranch)
        
        // Flush any pending progress updates
        container?.flush()
        
        // Configure upstream tracking branch so git status can show ahead/behind comparisons
        do {
            try setUpstreamBranch(localBranch: actualBranch, remoteName: remoteName, remoteBranch: actualBranch)
        } catch {
            log("REBASE - Warning - Failed to set upstream tracking: \(error.localizedDescription)")
            // Don't fail the pull if upstream tracking configuration fails
        }
        
        let totalDuration = Date().timeIntervalSince(startTime)
        log("REBASE - Successfully completed pull with rebase in \(String(format: "%.2f", totalDuration))s")
        pullSucceeded = true
    }
    
    public func fileExists(at path: String) -> Bool {
        guard let repo = repo else {
            log("Repository not initialized")
            return false
        }
        
        var headOid = git_oid()
        guard git_reference_name_to_id(&headOid, repo, "HEAD") == 0 else {
            log("No HEAD reference found (empty repository)")
            return false
        }
        
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &headOid) == 0, let headCommit = commit else {
            log("Failed to lookup HEAD commit")
            return false
        }
        defer { git_commit_free(headCommit) }
        
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, headCommit) == 0, let commitTree = tree else {
            log("Failed to get tree from commit")
            return false
        }
        defer { git_tree_free(commitTree) }
        
        var entry: OpaquePointer?
        let result = git_tree_entry_bypath(&entry, commitTree, path)
        
        if let treeEntry = entry {
            git_tree_entry_free(treeEntry)
        }
        
        return result == 0
    }

    // Resolves one commit tree and optional subtree for commit-scoped reads used by sync engines.
    private func resolveTreeAtCommit(commitOid: String, filepath: String) throws -> (tree: OpaquePointer, treeOid: String) {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var commitID = git_oid()
        guard git_oid_fromstr(&commitID, commitOid) == 0 else {
            throw GitError.repositoryError("Invalid commit OID: \(commitOid)")
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &commitID) == 0, let gitCommit = commit else {
            throw GitError.repositoryError("Failed to lookup commit: \(commitOid)")
        }
        defer { git_commit_free(gitCommit) }

        var rootTree: OpaquePointer?
        guard git_commit_tree(&rootTree, gitCommit) == 0, let commitTree = rootTree else {
            throw GitError.repositoryError("Failed to load tree for commit: \(commitOid)")
        }
        defer { git_tree_free(commitTree) }

        let normalizedPath = filepath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            guard let rootOid = git_tree_id(commitTree) else {
                throw GitError.repositoryError("Failed to resolve root tree OID for commit: \(commitOid)")
            }
            var oidBuffer = [Int8](repeating: 0, count: 41)
            var mutableRootOid = rootOid.pointee
            git_oid_tostr(&oidBuffer, 41, &mutableRootOid)
            var duplicatedTree: OpaquePointer?
            guard git_tree_dup(&duplicatedTree, commitTree) == 0, let copiedTree = duplicatedTree else {
                throw GitError.repositoryError("Failed to duplicate tree for commit: \(commitOid)")
            }
            return (copiedTree, String(cString: oidBuffer))
        }

        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, commitTree, normalizedPath) == 0, let treeEntry = entry else {
            throw GitError.repositoryError("Tree path not found in commit \(commitOid): \(filepath)")
        }
        defer { git_tree_entry_free(treeEntry) }

        guard git_tree_entry_type(treeEntry) == GIT_OBJECT_TREE,
              let subtreeOid = git_tree_entry_id(treeEntry) else {
            throw GitError.repositoryError("Path is not a tree in commit \(commitOid): \(filepath)")
        }

        var subtree: OpaquePointer?
        guard git_tree_lookup(&subtree, repo, subtreeOid) == 0, let resolvedSubtree = subtree else {
            throw GitError.repositoryError("Failed to lookup tree for path \(filepath) at commit \(commitOid)")
        }

        var oidBuffer = [Int8](repeating: 0, count: 41)
        var mutableSubtreeOid = subtreeOid.pointee
        git_oid_tostr(&oidBuffer, 41, &mutableSubtreeOid)
        return (resolvedSubtree, String(cString: oidBuffer))
    }

    // Converts a libgit2 tree entry into a value type so callers can recurse without raw pointers.
    private func makeTreeEntry(_ entry: OpaquePointer) -> GitTreeEntry? {
        guard let cName = git_tree_entry_name(entry),
              let entryOid = git_tree_entry_id(entry) else {
            return nil
        }
        var oidBuffer = [Int8](repeating: 0, count: 41)
        var mutableOid = entryOid.pointee
        git_oid_tostr(&oidBuffer, 41, &mutableOid)
        let objectType: GitTreeObjectType
        switch git_tree_entry_type(entry) {
        case GIT_OBJECT_BLOB:
            objectType = .blob
        case GIT_OBJECT_TREE:
            objectType = .tree
        default:
            objectType = .other
        }
        return GitTreeEntry(name: String(cString: cName), oid: String(cString: oidBuffer), type: objectType)
    }

    // Reads tree entries by tree OID so callers can recursively diff changed subtrees only.
    public func readTreeByOid(_ treeOid: String) throws -> [GitTreeEntry] {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var parsedOid = git_oid()
        guard git_oid_fromstr(&parsedOid, treeOid) == 0 else {
            throw GitError.repositoryError("Invalid tree OID: \(treeOid)")
        }

        var tree: OpaquePointer?
        guard git_tree_lookup(&tree, repo, &parsedOid) == 0, let gitTree = tree else {
            throw GitError.repositoryError("Failed to lookup tree OID: \(treeOid)")
        }
        defer { git_tree_free(gitTree) }

        let count = git_tree_entrycount(gitTree)
        var entries: [GitTreeEntry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let treeEntry = git_tree_entry_byindex(gitTree, index),
                  let value = makeTreeEntry(treeEntry) else {
                continue
            }
            entries.append(value)
        }
        return entries
    }

    // Reads a subtree at a specific commit so sync code can diff manifests between commits efficiently.
    public func readTreeAtCommit(commitOid: String, filepath: String) throws -> (oid: String, entries: [GitTreeEntry])? {
        do {
            let (tree, treeOid) = try resolveTreeAtCommit(commitOid: commitOid, filepath: filepath)
            defer { git_tree_free(tree) }

            let count = git_tree_entrycount(tree)
            var entries: [GitTreeEntry] = []
            entries.reserveCapacity(Int(count))
            for index in 0..<count {
                guard let treeEntry = git_tree_entry_byindex(tree, index),
                      let value = makeTreeEntry(treeEntry) else {
                    continue
                }
                entries.append(value)
            }
            return (treeOid, entries)
        } catch GitError.repositoryError(let message) where message.contains("Tree path not found") {
            return nil
        } catch {
            throw error
        }
    }

    // Reads one blob at a specific commit/path without moving HEAD so incremental sync can load old/new versions.
    public func readBlobDataAtCommit(commitOid: String, filepath: String) throws -> Data? {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var commitID = git_oid()
        guard git_oid_fromstr(&commitID, commitOid) == 0 else {
            throw GitError.repositoryError("Invalid commit OID: \(commitOid)")
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &commitID) == 0, let gitCommit = commit else {
            throw GitError.repositoryError("Failed to lookup commit: \(commitOid)")
        }
        defer { git_commit_free(gitCommit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, gitCommit) == 0, let commitTree = tree else {
            throw GitError.repositoryError("Failed to get tree for commit: \(commitOid)")
        }
        defer { git_tree_free(commitTree) }

        let normalizedPath = filepath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, commitTree, normalizedPath) == 0, let treeEntry = entry else {
            return nil
        }
        defer { git_tree_entry_free(treeEntry) }

        guard git_tree_entry_type(treeEntry) == GIT_OBJECT_BLOB else {
            throw GitError.repositoryError("Path is not a blob at commit \(commitOid): \(filepath)")
        }
        guard let blobOid = git_tree_entry_id(treeEntry) else {
            throw GitError.repositoryError("Failed to resolve blob OID for path \(filepath) at commit \(commitOid)")
        }

        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, blobOid) == 0, let gitBlob = blob else {
            throw GitError.repositoryError("Failed to lookup blob for path \(filepath) at commit \(commitOid)")
        }
        defer { git_blob_free(gitBlob) }

        let rawSize = git_blob_rawsize(gitBlob)
        if rawSize == 0 {
            return Data()
        }
        guard let rawContent = git_blob_rawcontent(gitBlob) else {
            throw GitError.repositoryError("Failed to read blob content for path \(filepath) at commit \(commitOid)")
        }
        return Data(bytes: rawContent, count: Int(rawSize))
    }

    // Reads blob bytes directly by blob OID so full hydration can avoid repeated path-to-tree traversal.
    public func readBlobDataByOid(_ blobOid: String) throws -> Data {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var parsedOid = git_oid()
        guard git_oid_fromstr(&parsedOid, blobOid) == 0 else {
            throw GitError.repositoryError("Invalid blob OID: \(blobOid)")
        }

        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, &parsedOid) == 0, let gitBlob = blob else {
            throw GitError.repositoryError("Failed to lookup blob for OID: \(blobOid)")
        }
        defer { git_blob_free(gitBlob) }

        let rawSize = git_blob_rawsize(gitBlob)
        if rawSize == 0 {
            return Data()
        }
        guard let rawContent = git_blob_rawcontent(gitBlob) else {
            throw GitError.repositoryError("Failed to read blob content for OID: \(blobOid)")
        }
        return Data(bytes: rawContent, count: Int(rawSize))
    }

    func readBlobDataFromHead(at path: String) throws -> Data {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var headOid = git_oid()
        guard git_reference_name_to_id(&headOid, repo, "HEAD") == 0 else {
            throw GitError.repositoryError("No HEAD reference found")
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &headOid) == 0, let headCommit = commit else {
            throw GitError.repositoryError("Failed to lookup HEAD commit")
        }
        defer { git_commit_free(headCommit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, headCommit) == 0, let commitTree = tree else {
            throw GitError.repositoryError("Failed to get tree from commit")
        }
        defer { git_tree_free(commitTree) }

        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, commitTree, normalizedPath) == 0, let treeEntry = entry else {
            throw GitError.repositoryError("File not found in git tree: \(path)")
        }
        defer { git_tree_entry_free(treeEntry) }

        guard git_tree_entry_type(treeEntry) == GIT_OBJECT_BLOB else {
            throw GitError.repositoryError("Path is not a file: \(path)")
        }
        guard let blobOid = git_tree_entry_id(treeEntry) else {
            throw GitError.repositoryError("Failed to resolve blob OID for path: \(path)")
        }

        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, blobOid) == 0, let gitBlob = blob else {
            throw GitError.repositoryError("Failed to lookup blob for path: \(path)")
        }
        defer { git_blob_free(gitBlob) }

        let rawSize = git_blob_rawsize(gitBlob)
        if rawSize == 0 {
            return Data()
        }
        guard let rawContent = git_blob_rawcontent(gitBlob) else {
            throw GitError.repositoryError("Failed to read blob content for path: \(path)")
        }
        return Data(bytes: rawContent, count: Int(rawSize))
    }

    func listTreeEntriesFromHead(in directory: String) throws -> [String] {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        let normalizedDirectory = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var headOid = git_oid()
        guard git_reference_name_to_id(&headOid, repo, "HEAD") == 0 else {
            return []
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &headOid) == 0, let headCommit = commit else {
            return []
        }
        defer { git_commit_free(headCommit) }

        var rootTree: OpaquePointer?
        guard git_commit_tree(&rootTree, headCommit) == 0, let commitTree = rootTree else {
            return []
        }
        defer { git_tree_free(commitTree) }

        let treeToList: OpaquePointer
        var subTreeToFree: OpaquePointer?
        defer {
            if let subTreeToFree {
                git_tree_free(subTreeToFree)
            }
        }
        if normalizedDirectory.isEmpty {
            treeToList = commitTree
        } else {
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, commitTree, normalizedDirectory) == 0, let treeEntry = entry else {
                return []
            }
            defer { git_tree_entry_free(treeEntry) }

            guard git_tree_entry_type(treeEntry) == GIT_OBJECT_TREE,
                  let treeOid = git_tree_entry_id(treeEntry) else {
                return []
            }

            var resolvedTree: OpaquePointer?
            guard git_tree_lookup(&resolvedTree, repo, treeOid) == 0, let subTree = resolvedTree else {
                return []
            }
            subTreeToFree = subTree
            treeToList = subTree
        }

        let count = git_tree_entrycount(treeToList)
        var files: [String] = []
        files.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let entry = git_tree_entry_byindex(treeToList, index),
                  let cName = git_tree_entry_name(entry) else {
                continue
            }
            let name = String(cString: cName)
            files.append(normalizedDirectory.isEmpty ? name : "\(normalizedDirectory)/\(name)")
        }
        return files
    }

    func syncIndexFromHead(index: OpaquePointer) throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var headOid = git_oid()
        guard git_reference_name_to_id(&headOid, repo, "HEAD") == 0 else {
            // No commits yet.
            return
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &headOid) == 0, let headCommit = commit else {
            throw GitError.repositoryError("Failed to lookup HEAD commit")
        }
        defer { git_commit_free(headCommit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, headCommit) == 0, let headTree = tree else {
            throw GitError.repositoryError("Failed to get tree from HEAD commit")
        }
        defer { git_tree_free(headTree) }

        guard git_index_read_tree(index, headTree) == 0 else {
            throw GitError.repositoryError("Failed to sync index from HEAD tree")
        }
    }

    func syncIndexFromHead() throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }

        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let idx = index else {
            throw GitError.repositoryError("Failed to get repository index")
        }
        defer { git_index_free(idx) }

        try syncIndexFromHead(index: idx)

        guard git_index_write(idx) == 0 else {
            throw GitError.repositoryError("Failed to write synced index")
        }
    }

    // Creates a packfile suitable for pushing a ref update by including the commit range the remote is missing.
    // This avoids server-side "missing necessary objects" failures when the tip commit's parents aren't already present remotely.
    public func createPackfile(forCommit commitOID: String, since baseOID: String? = nil) throws -> Data {
        let createPackfileSignpost = GitSignposts.begin("GitCreatePackfile")
        var createPackfileSucceeded = false
        var packfileObjectCount: Int = 0
        var packfileByteCount: Int = 0
        defer {
            if createPackfileSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitCreatePackfile",
                    createPackfileSignpost,
                    "objects=\(packfileObjectCount, privacy: .public) bytes=\(packfileByteCount, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitCreatePackfile", createPackfileSignpost)
            }
        }
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        log("Creating packfile for commit: \(commitOID) (base: \(baseOID ?? "none")")
        
        // Parse the commit OID
        var oid = git_oid()
        guard git_oid_fromstr(&oid, commitOID) == 0 else {
            throw GitError.repositoryError("Invalid commit OID: \(commitOID)")
        }
        
        // Build a revwalk for the range we need to send to the remote.
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repo) == 0, let revwalk = walk else {
            throw GitError.repositoryError("Failed to create revwalk")
        }
        defer { git_revwalk_free(revwalk) }
        
        // Prefer topo sorting so commits come out in a sensible order for transport and server-side connectivity checks.
        git_revwalk_sorting(revwalk, UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        
        guard git_revwalk_push(revwalk, &oid) == 0 else {
            throw GitError.repositoryError("Failed to start revwalk from \(commitOID)")
        }
        
        if let baseOID, baseOID != String(repeating: "0", count: 40) {
            var base = git_oid()
            guard git_oid_fromstr(&base, baseOID) == 0 else {
                throw GitError.repositoryError("Invalid base OID: \(baseOID)")
            }
            // Hiding the base ensures we only send objects that aren't already reachable from the remote's current tip.
            _ = git_revwalk_hide(revwalk, &base)
        }
        
        // Create a new packbuilder
        var packbuilder: OpaquePointer?
        guard git_packbuilder_new(&packbuilder, repo) == 0, let pb = packbuilder else {
            throw GitError.repositoryError("Failed to create packbuilder")
        }
        defer { git_packbuilder_free(pb) }
        
        log("Packbuilder created")
        
        // Insert the revwalk range so the push includes any missing parent commits (and their referenced trees/blobs).
        let insertResult = git_packbuilder_insert_walk(pb, revwalk)
        guard insertResult == 0 else {
            log("Failed to insert revwalk into packbuilder, error code: \(insertResult)")
            throw GitError.repositoryError("Failed to insert revwalk into packbuilder")
        }
        
        let objectCount = git_packbuilder_object_count(pb)
        packfileObjectCount = Int(objectCount)
        log("Inserted revwalk, packbuilder contains \(objectCount) objects")
        
        // Write the packfile to a buffer
        var buf = git_buf()
        let writeResult = git_packbuilder_write_buf(&buf, pb)
        guard writeResult == 0 else {
            log("Failed to write packfile to buffer, error code: \(writeResult)")
            throw GitError.repositoryError("Failed to write packfile")
        }
        defer { git_buf_dispose(&buf) }
        
        // Convert git_buf to Data
        let packfileData = Data(bytes: buf.ptr, count: buf.size)
        packfileByteCount = packfileData.count
        log("Created packfile with \(packfileData.count) bytes")
        
        createPackfileSucceeded = true
        return packfileData
    }
    
    // Creates a packfile containing the specified commit and all objects it references.
    // Used when the caller doesn't have a remote base OID to compute an incremental range.
    public func createPackfile(forCommit commitOID: String) throws -> Data {
        try createPackfile(forCommit: commitOID, since: nil)
    }
    
    public func getStatus() -> String {
        guard let repo = repo else {
            return "Repository not initialized"
        }
        
        log("getStatus() starting...")
        let totalStartTime = Date()
        
        var result = ""
        
        var head: OpaquePointer?
        if git_repository_head(&head, repo) == 0, let headRef = head {
            defer { git_reference_free(headRef) }
            
            if let branchName = git_reference_shorthand(headRef) {
                let branch = String(cString: branchName)
                result += "On branch \(branch)\n"
                
                var upstream: OpaquePointer?
                if git_branch_upstream(&upstream, headRef) == 0, let upstreamRef = upstream {
                    defer { git_reference_free(upstreamRef) }
                    
                    let localOid = git_reference_target(headRef)
                    let upstreamOid = git_reference_target(upstreamRef)
                    
                    if let local = localOid, let remote = upstreamOid {
                        log("Computing ahead/behind...")
                        let aheadBehindStart = Date()
                        var ahead: size_t = 0
                        var behind: size_t = 0
                        if git_graph_ahead_behind(&ahead, &behind, repo, local, remote) == 0 {
                            let aheadBehindDuration = Date().timeIntervalSince(aheadBehindStart)
                            log("Ahead/behind computed in \(String(format: "%.3f", aheadBehindDuration))s: ahead=\(ahead), behind=\(behind)")
                            if ahead > 0 && behind == 0 {
                                result += "Your branch is ahead of upstream by \(ahead) commit\(ahead == 1 ? "" : "s").\n"
                            } else if ahead == 0 && behind > 0 {
                                result += "Your branch is behind upstream by \(behind) commit\(behind == 1 ? "" : "s").\n"
                            } else if ahead > 0 && behind > 0 {
                                result += "Your branch has diverged from upstream by \(ahead) ahead and \(behind) behind.\n"
                            } else {
                                result += "Your branch is up to date with upstream.\n"
                            }
                        }
                    }
                }
            }
        }
        
        log("Creating status list...")
        let statusListStart = Date()
        var statusOptions = git_status_options()
        let optionsResult = git_status_options_init(&statusOptions, UInt32(GIT_STATUS_OPTIONS_VERSION))
        guard optionsResult == 0 else {
            return result + "Failed to initialize status options"
        }
        
        // Only check the git index for performance with large repositories containing thousands of files.
        // Checking the working directory (GIT_STATUS_SHOW_INDEX_AND_WORKDIR) requires scanning every
        // tracked file's timestamp/size, which is extremely slow with many binary media files.
        statusOptions.show = GIT_STATUS_SHOW_INDEX_ONLY
        statusOptions.flags = UInt32(GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue)
        
        var statusList: OpaquePointer?
        let statusResult = git_status_list_new(&statusList, repo, &statusOptions)
        guard statusResult == 0, let list = statusList else {
            return result + "Failed to get status"
        }
        defer { git_status_list_free(list) }
        
        let statusListDuration = Date().timeIntervalSince(statusListStart)
        log("Status list created in \(String(format: "%.3f", statusListDuration))s")
        
        let count = git_status_list_entrycount(list)
        log("Processing \(count) status entries...")
        
        if count == 0 {
            if result.isEmpty {
                return "Index clean"
            }
            result += "\nIndex clean"
            let totalDuration = Date().timeIntervalSince(totalStartTime)
            log("getStatus() completed in \(String(format: "%.3f", totalDuration))s")
            return result
        }
        
        var staged: [String] = []
        
        for i in 0..<count {
            guard let entry = git_status_byindex(list, i) else { continue }
            
            // With INDEX_ONLY mode, we only get head_to_index entries (staged changes)
            if let path = entry.pointee.head_to_index?.pointee.new_file.path {
                let fileName = String(cString: path)
                staged.append(fileName)
            }
        }
        
        if !result.isEmpty { result += "\n" }
        
        if !staged.isEmpty {
            result += "Staged (\(staged.count)):\n"
            for file in staged.prefix(5) {
                result += "  + \(file)\n"
            }
            if staged.count > 5 {
                result += "  ... and \(staged.count - 5) more\n"
            }
        }
        
        let totalDuration = Date().timeIntervalSince(totalStartTime)
        log("getStatus() completed in \(String(format: "%.3f", totalDuration))s")
        return result
    }
    
    // Imports a packfile into the repository's object database.
    // Returns the number of objects imported.
    public func applyPackfile(_ packfile: Data) throws -> Int {
        let applyPackfileSignpost = GitSignposts.begin("GitApplyPackfile")
        var applyPackfileSucceeded = false
        var importedObjectCount = 0
        defer {
            if applyPackfileSucceeded {
                GitSignposts.signposter.endInterval(
                    "GitApplyPackfile",
                    applyPackfileSignpost,
                    "inputBytes=\(packfile.count, privacy: .public) importedObjects=\(importedObjectCount, privacy: .public)"
                )
            } else {
                GitSignposts.end("GitApplyPackfile", applyPackfileSignpost)
            }
        }
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        guard !packfile.isEmpty else {
            log("Empty packfile, nothing to import")
            applyPackfileSucceeded = true
            return 0
        }
        
        log("Applying packfile of \(packfile.count) bytes")
        
        // Get the repository's object database
        var odb: OpaquePointer?
        guard git_repository_odb(&odb, repo) == 0, let objectDB = odb else {
            throw GitError.repositoryError("Failed to get object database")
        }
        defer { git_odb_free(objectDB) }
        
        // Get the objects directory path for the indexer
        guard let repoPath = git_repository_path(repo) else {
            throw GitError.repositoryError("Failed to get repository path")
        }
        let objectsPath = String(cString: repoPath) + "objects"
        
        // Create an indexer to process the packfile
        var indexer: OpaquePointer?
        var indexerOptions = git_indexer_options()
        git_indexer_options_init(&indexerOptions, UInt32(GIT_INDEXER_OPTIONS_VERSION))
        
        let indexerResult = git_indexer_new(&indexer, objectsPath, 0, objectDB, &indexerOptions)
        guard indexerResult == 0, let idx = indexer else {
            log("Failed to create indexer, error code: \(indexerResult)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to create indexer: \(error)")
        }
        defer { git_indexer_free(idx) }
        
        log("Created indexer for packfile import")
        
        // Feed the packfile data to the indexer
        var stats = git_indexer_progress()
        let appendResult = packfile.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            git_indexer_append(idx, bytes.baseAddress, packfile.count, &stats)
        }
        
        guard appendResult == 0 else {
            log("Failed to append packfile data, error code: \(appendResult)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to process packfile: \(error)")
        }
        
        log("Processed packfile - received: \(stats.received_objects), indexed: \(stats.indexed_objects)")
        
        // Commit the indexer (writes the pack and index files)
        let commitResult = git_indexer_commit(idx, &stats)
        guard commitResult == 0 else {
            log("Failed to commit indexer, error code: \(commitResult)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to finalize packfile: \(error)")
        }
        
        let objectCount = Int(stats.indexed_objects)
        importedObjectCount = objectCount
        log("Successfully imported \(objectCount) objects from packfile")
        
        applyPackfileSucceeded = true
        return objectCount
    }
    
    // Updates a remote-tracking reference to point to a new commit.
    public func updateRemoteRef(remoteName: String, branchName: String, oid: String) throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        let refName = "refs/remotes/\(remoteName)/\(branchName)"
        log("Updating \(refName) to \(oid)")
        
        var targetOid = git_oid()
        guard git_oid_fromstr(&targetOid, oid) == 0 else {
            throw GitError.repositoryError("Invalid OID: \(oid)")
        }
        
        var ref: OpaquePointer?
        let refResult = git_reference_create(&ref, repo, refName, &targetOid, 1, "fetch: fast-forward")
        
        if let reference = ref {
            git_reference_free(reference)
        }
        
        guard refResult == 0 else {
            log("Failed to update reference, error code: \(refResult)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to update remote ref: \(error)")
        }
        
        log("Successfully updated \(refName)")
    }
    
    // Gets the current HEAD commit OID as a string.
    public func headOID() -> String? {
        guard let repo = repo else {
            return nil
        }
        
        var headOid = git_oid()
        guard git_reference_name_to_id(&headOid, repo, "HEAD") == 0 else {
            return nil
        }
        
        var oidStr = [Int8](repeating: 0, count: 41)
        git_oid_tostr(&oidStr, 41, &headOid)
        return String(cString: oidStr)
    }
    
    // Performs a fast-forward merge to a target commit OID.
    // This is used when pulling remote changes that are ahead of local.
    public func fastForward(toOID oidString: String, branchName: String) throws {
        guard let repo = repo else {
            throw GitError.repositoryError("Repository not initialized")
        }
        
        log("Fast-forwarding \(branchName) to \(oidString)")
        
        var targetOid = git_oid()
        guard git_oid_fromstr(&targetOid, oidString) == 0 else {
            throw GitError.repositoryError("Invalid OID: \(oidString)")
        }
        
        // Update the branch reference
        let refName = "refs/heads/\(branchName)"
        var ref: OpaquePointer?
        let refResult = git_reference_create(&ref, repo, refName, &targetOid, 1, "pull: fast-forward")
        
        if let reference = ref {
            git_reference_free(reference)
        }
        
        guard refResult == 0 else {
            log("Failed to update branch reference, error code: \(refResult)")
            let error = GitError.fromGitError()
            throw GitError.repositoryError("Failed to fast-forward: \(error)")
        }
        
        // Update HEAD
        let headResult = git_repository_set_head(repo, refName)
        guard headResult == 0 else {
            log("Failed to set HEAD, error code: \(headResult)")
            throw GitError.repositoryError("Failed to update HEAD")
        }

        try syncIndexFromHead()
        
        log("Successfully fast-forwarded to \(oidString)")
    }
}

// Serializes mutating libgit2 operations for one repository instance.
private actor RepositoryMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Acquires exclusive mutation ownership, suspending callers until prior mutation finishes.
    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // Acquires exclusive mutation ownership only if it is currently available.
    func tryAcquire() -> Bool {
        if isLocked {
            return false
        }
        isLocked = true
        return true
    }

    // Hands ownership to the next waiter, or unlocks when no waiters remain.
    func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

