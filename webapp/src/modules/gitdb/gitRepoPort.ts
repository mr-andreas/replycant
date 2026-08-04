import { OnboardingAuthorizationProbe, SyncCommitSummary } from "./syncTypes";

// Defines the only repo-control surface gitdb internals use so callers cannot bypass module ownership.
export interface GitRepoPort {
  listRecentLocalCommits(limit?: number): Promise<SyncCommitSummary[]>;
  readTrackedRemoteHeadCommitHashOrNull(): Promise<string | null>;
  rewindToCommitAndPausePolling(commitHash: string): Promise<void>;
  forwardToRemoteHeadAndResumePolling(): Promise<void>;
  hardResetToRemoteAfterPermission(): Promise<void>;
  probeOnboardingAuthorization(): Promise<OnboardingAuthorizationProbe>;
}
