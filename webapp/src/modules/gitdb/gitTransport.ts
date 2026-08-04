import git from "isomorphic-git";
import webHttp from "isomorphic-git/http/web";
import LightningFS from "@isomorphic-git/lightning-fs";
import type { SyncEngineConfig, OnboardingAuthorizationProbe, MtlsHeadersProvider } from "./syncTypes";

const DEFAULT_INITIAL_CLONE_DEPTH = 1;

const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

const nowMs = (): number => Date.now();

// Wraps isomorphic-git's web HTTP transport with cache-busting on GET requests
// to prevent the browser from serving a stale protocol-v2 ref advertisement
// when git.fetch (protocol v1) follows listServerRefs (protocol v2) for the
// same info/refs URL.
const http = {
  request(args: Parameters<typeof webHttp.request>[0]) {
    if (!args.method || args.method === "GET") {
      const sep = args.url.includes("?") ? "&" : "?";
      return webHttp.request({ ...args, url: `${args.url}${sep}_t=${Date.now()}` });
    }
    return webHttp.request(args);
  },
};

const normalizeInitialCloneDepth = (depth: number | undefined): number => {
  if (!Number.isInteger(depth) || (depth ?? 0) < 1) return DEFAULT_INITIAL_CLONE_DEPTH;
  return depth ?? DEFAULT_INITIAL_CLONE_DEPTH;
};

// Reports pull divergence as a recoverable state so UI can ask for explicit
// reset approval.
export class PullRebaseConflictError extends Error {}

export type GitProgressCallback = (event: {
  phase?: string;
  loaded?: number;
  total?: number;
}) => void;

// Isolates git network and ref operations from sync orchestration so transport
// concerns (clone, fetch, ref resolution, checkout) are testable independently.
export class GitTransport {
  readonly fs: LightningFS;
  readonly gitdir = "/repo";
  private readonly config: SyncEngineConfig;
  private readonly mtlsHeadersProvider: MtlsHeadersProvider;
  private readonly log: (event: string, fields: Record<string, unknown>) => void;
  private readonly onProgress: GitProgressCallback;
  // Shared with every other gitdb collaborator so isomorphic-git only parses
  // each pack index once per engine lifetime instead of per call. Cache identity
  // is the entire point - never replace this reference.
  private readonly cache: object;

  get localBranchRef(): string {
    return `refs/heads/${this.config.gitBranch}`;
  }

  get trackedRemoteRef(): string {
    return `refs/remotes/origin/${this.config.gitBranch}`;
  }

  constructor(opts: {
    config: SyncEngineConfig;
    fs: LightningFS;
    mtlsHeadersProvider: MtlsHeadersProvider;
    log: (event: string, fields: Record<string, unknown>) => void;
    onProgress: GitProgressCallback;
    cache: object;
  }) {
    this.config = opts.config;
    this.fs = opts.fs;
    this.mtlsHeadersProvider = opts.mtlsHeadersProvider;
    this.log = opts.log;
    this.onProgress = opts.onProgress;
    this.cache = opts.cache;
  }

  // Coordinates clone/fetch plus rebase-style fast-forward so pull behavior
  // remains deterministic. Accepts the currently synced commit hash to decide
  // fast-forward eligibility.
  async pullWithRebase(syncedCommitHash: string | null): Promise<string> {
    const pfs = this.fs.promises;
    const hasMtls = Boolean(this.currentMtlsHeaders());
    this.onProgress({ phase: "Connecting to server", loaded: 0 });
    let hasInitializedRepo = false;
    try {
      await pfs.stat(`${this.gitdir}/HEAD`);
      hasInitializedRepo = true;
    } catch {
      hasInitializedRepo = false;
    }
    this.log("pullWithRebase-start", {
      hasInitializedRepo,
      hasMtlsHeaders: hasMtls,
      remoteUrl: this.config.gitRemoteUrl,
      branch: this.config.gitBranch,
    });

    if (hasInitializedRepo) {
      try {
        const localBranch = await this.resolveRefOrNull(this.localBranchRef);
        const remoteTracking = await this.resolveRefOrNull(this.trackedRemoteRef);
        this.log("pullWithRebase-local-state", { localBranch, remoteTracking });
      } catch (error) {
        this.log("pullWithRebase-local-state-error", {
          error: errorMessage(error),
        });
      }
    }

    if (!hasInitializedRepo) {
      await this.ensureRepoDirectory();
      await this.ensureRemoteBranchReadyForInitialClone();
      try {
        const cloneStartedAtMs = nowMs();
        this.log("clone-start", {
          url: this.config.gitRemoteUrl,
          branch: this.config.gitBranch,
          depth: normalizeInitialCloneDepth(this.config.initialCloneDepth),
        });
        await git.clone({
          fs: this.fs,
          http,
          dir: this.gitdir,
          gitdir: this.gitdir,
          url: this.config.gitRemoteUrl,
          ref: this.config.gitBranch,
          singleBranch: true,
          depth: normalizeInitialCloneDepth(this.config.initialCloneDepth),
          noCheckout: true,
          headers: this.currentMtlsHeaders() ?? undefined,
          onProgress: this.onProgress,
          cache: this.cache,
        });
        const head = await git.resolveRef({ fs: this.fs, dir: this.gitdir, gitdir: this.gitdir, ref: "HEAD" });
        this.log("clone-complete", { headCommitHash: head, durationMs: nowMs() - cloneStartedAtMs });
        return head;
      } catch (error) {
        const detail = errorMessage(error);
        this.log("clone-failed", {
          error: detail,
          stack: error instanceof Error ? error.stack : undefined,
          isAlreadyExists: detail.includes("already exists"),
        });
        if (!detail.includes("already exists")) throw error;
        return this.pullLatestWithRebase(syncedCommitHash);
      }
    }

    return this.pullLatestWithRebase(syncedCommitHash);
  }

  // Preflights remote refs before first clone so onboarding failures become
  // explicit setup guidance.
  async ensureRemoteBranchReadyForInitialClone(): Promise<void> {
    const preflightStartedAtMs = nowMs();
    try {
      const refs = await git.listServerRefs({
        http,
        url: this.config.gitRemoteUrl,
        prefix: this.localBranchRef,
        headers: this.currentMtlsHeaders() ?? undefined,
      });
      const hasTrackedBranch = refs.some((entry) => entry.ref === this.localBranchRef);
      this.log("clone-preflight-refs", {
        refsCount: refs.length,
        hasTrackedBranch,
        durationMs: nowMs() - preflightStartedAtMs,
      });
      if (!hasTrackedBranch) {
        throw new Error(
          `Remote branch ${this.localBranchRef} is missing. Push the initial commit before syncing.`,
        );
      }
    } catch (error) {
      const detail = errorMessage(error);
      if (detail.includes("remoteRefs is undefined")) {
        throw new Error(
          "Git upstream protocol mismatch while listing refs. Verify `/api/git` routes to the local proxy and gitd.",
        );
      }
      throw error;
    }
  }

  // Reconciles local and remote refs by ancestry so only true divergence is
  // treated as conflict.
  async pullLatestWithRebase(syncedCommitHash: string | null): Promise<string> {
    const fetchStartedAtMs = nowMs();
    this.log("fetch-start", {
      url: this.config.gitRemoteUrl,
      branch: this.config.gitBranch,
      hasMtlsHeaders: Boolean(this.currentMtlsHeaders()),
    });
    try {
      await this.fetchFromRemote();
    } catch (error) {
      this.log("fetch-failed", {
        error: errorMessage(error),
        stack: error instanceof Error ? error.stack : undefined,
      });
      throw error;
    }
    this.log("fetch-complete", { branch: this.config.gitBranch, durationMs: nowMs() - fetchStartedAtMs });

    const localHead = await this.resolveRefOrNull(this.localBranchRef);
    const remoteHead = await this.resolveRefOrNull(this.trackedRemoteRef);
    this.log("rebase-refs", { localHead, remoteHead, syncedCommitHash });

    if (!remoteHead) {
      throw new Error(`Remote branch ${this.config.gitBranch} is missing after fetch.`);
    }

    const canFastForward =
      !localHead ||
      localHead === remoteHead ||
      (syncedCommitHash && localHead === syncedCommitHash) ||
      await git.isDescendent({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: remoteHead,
        ancestor: localHead,
        cache: this.cache,
      });

    if (canFastForward) {
      await this.forceCheckoutCommit(this.localBranchRef, remoteHead);
      return remoteHead;
    }

    throw new PullRebaseConflictError(
      "Local branch state does not match last synced state and requires explicit reset.",
    );
  }

  // Hard-resets branch to remote tip so user-approved recovery can clear
  // divergence safely.
  async hardResetToRemote(): Promise<void> {
    await this.fetchFromRemote();
    const remoteHead = await this.resolveRefOrNull(this.trackedRemoteRef);
    if (!remoteHead) {
      throw new Error(`Remote ref ${this.trackedRemoteRef} is missing and reset cannot continue.`);
    }
    await this.forceCheckoutCommit(this.localBranchRef, remoteHead);
  }

  async resolveRefOrNull(ref: string): Promise<string | null> {
    try {
      return await git.resolveRef({ fs: this.fs, dir: this.gitdir, gitdir: this.gitdir, ref });
    } catch {
      return null;
    }
  }

  // Reads remote branch head without fetching pack data so no-op sync checks
  // stay lightweight.
  async readRemoteBranchHeadCommitHashOrNull(): Promise<string | null> {
    const hasMtls = Boolean(this.currentMtlsHeaders());
    const listRefsStartedAtMs = nowMs();
    this.log("listServerRefs-start", {
      url: this.config.gitRemoteUrl,
      branch: this.config.gitBranch,
      hasMtlsHeaders: hasMtls,
    });
    try {
      const refs = await git.listServerRefs({
        http,
        url: this.config.gitRemoteUrl,
        prefix: this.localBranchRef,
        headers: this.currentMtlsHeaders() ?? undefined,
      });
      const match = refs.find((r) => r.ref === this.localBranchRef);
      this.log("listServerRefs-result", {
        refsCount: refs.length,
        matchedOid: match?.oid ?? null,
        allRefs: refs.map((r) => ({ ref: r.ref, oid: r.oid.slice(0, 8) })),
        durationMs: nowMs() - listRefsStartedAtMs,
      });
      return match?.oid ?? null;
    } catch (error) {
      this.log("listServerRefs-failed", {
        error: errorMessage(error),
        stack: error instanceof Error ? error.stack : undefined,
      });
      return null;
    }
  }

  // Separates onboarding wait states from fatal setup failures so QR
  // authorization does not stall silently.
  async probeOnboardingAuthorization(): Promise<OnboardingAuthorizationProbe> {
    this.log("onboarding-probe-start", { url: this.config.gitRemoteUrl, branch: this.config.gitBranch });
    try {
      const refs = await git.listServerRefs({
        http,
        url: this.config.gitRemoteUrl,
        prefix: this.localBranchRef,
        headers: this.currentMtlsHeaders() ?? undefined,
      });
      const match = refs.find((r) => r.ref === this.localBranchRef);
      if (match?.oid) {
        this.log("onboarding-probe-authorized", { remoteHead: match.oid });
        return { status: "authorized", remoteHead: match.oid };
      }
      const missingBranchMessage =
        `Remote branch ${this.localBranchRef} is missing. ` +
        "Push the initial commit before authorizing this key.";
      this.log("onboarding-probe-missing-branch", {
        refsCount: refs.length,
        refs: refs.map((entry) => entry.ref),
      });
      return { status: "fatal_error", message: missingBranchMessage };
    } catch (error) {
      const message = errorMessage(error);
      const normalized = message.toLowerCase();
      this.log("onboarding-probe-failed", {
        error: message,
        stack: error instanceof Error ? error.stack : undefined,
      });
      if (
        normalized.includes("401") ||
        normalized.includes("unauthorized") ||
        normalized.includes("authentication failed")
      ) {
        return { status: "pending_authorization" };
      }
      if (
        normalized.includes("econnrefused") ||
        normalized.includes("fetch failed") ||
        normalized.includes("networkerror") ||
        normalized.includes("socket hang up") ||
        normalized.includes("timed out") ||
        normalized.includes("enotfound")
      ) {
        return {
          status: "transient_error",
          message: `Cannot reach git server yet (${message}). Retrying...`,
        };
      }
      if (normalized.includes("remoteRefs is undefined".toLowerCase())) {
        return {
          status: "fatal_error",
          message:
            "Git proxy returned a non-git response while checking authorization. Verify `/api/git` proxy routing and gitd.",
        };
      }
      if (normalized.includes("git upstream protocol mismatch")) {
        return {
          status: "fatal_error",
          message: "Git proxy protocol mismatch while checking authorization. Verify proxy target and gitd availability.",
        };
      }
      return {
        status: "fatal_error",
        message: `Authorization check failed: ${message}`,
      };
    }
  }

  currentMtlsHeaders(): Record<string, string> | null {
    const headers = this.mtlsHeadersProvider();
    return headers ? { ...headers } : null;
  }

  async fetchFromRemote(): Promise<void> {
    await git.fetch({
      fs: this.fs,
      http,
      dir: this.gitdir,
      gitdir: this.gitdir,
      url: this.config.gitRemoteUrl,
      ref: this.config.gitBranch,
      singleBranch: true,
      headers: this.currentMtlsHeaders() ?? undefined,
      onProgress: this.onProgress,
      cache: this.cache,
    });
  }

  // Forces branch/HEAD refs to the target commit so cache refresh reflects one
  // authoritative revision. Validates that the target OID exists locally
  // before touching any refs so a missing/typo'd commit cannot leave the
  // branch pointing at a dangling object and force a hard-reset recovery.
  async forceCheckoutCommit(branchRef: string, targetOid: string): Promise<void> {
    this.log("checkout-force-start", { branchRef, targetOid });
    const validateStartedAtMs = nowMs();
    try {
      await git.expandOid({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: targetOid,
        cache: this.cache,
      });
    } catch (error) {
      const detail = errorMessage(error);
      this.log("checkout-force-validate-failed", { branchRef, targetOid, error: detail });
      throw new Error(`Refusing to checkout missing commit ${targetOid}: ${detail}`);
    }
    this.log("checkout-force-validate-complete", {
      branchRef,
      targetOid,
      durationMs: nowMs() - validateStartedAtMs,
    });
    await git.writeRef({
      fs: this.fs,
      dir: this.gitdir,
      gitdir: this.gitdir,
      ref: branchRef,
      value: targetOid,
      force: true,
    });
    this.log("checkout-force-write-ref-complete", { branchRef, targetOid });
    await git.writeRef({
      fs: this.fs,
      dir: this.gitdir,
      gitdir: this.gitdir,
      ref: "HEAD",
      value: branchRef,
      force: true,
      symbolic: true,
    });
    this.log("checkout-force-complete", { branchRef, targetOid });
  }

  async ensureRepoDirectory(): Promise<void> {
    const pfs = this.fs.promises;
    try {
      await pfs.mkdir(this.gitdir);
    } catch (error) {
      const detail = errorMessage(error);
      if (!detail.includes("EEXIST")) throw error;
    }
  }
}
