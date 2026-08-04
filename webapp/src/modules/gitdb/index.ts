export { createGitdb } from "./gitdb";
export type { CreateGitdbOptions, GitdbClient } from "./gitdb";
export { createGitdbWorker } from "./gitdbWorkerClient";
export type { GitdbWorkerClient } from "./gitdbWorkerClient";
export type { GitdbCallbacks } from "./contracts";

export { ManifestRegistry, deriveManifestStoreName } from "./manifestRegistry";
export type { ManifestKindRegistration, ManifestIndexDefinition, RegisteredManifestRecord } from "./manifestRegistry";
export { ManifestDatabase } from "./manifestDatabase";
export type { DerivedStoreQueryRequest, ManifestQueryRequest, ManifestQueryIdentity, SerializableKeyRange } from "./manifestDatabase";

export type { MonthCountRow } from "./timelineDerivedStores";

export {
  buildMtlsHeaders,
  buildPublicKeyQrPayload,
  clearIdentityRecord,
  computeCaHash,
  createIdentity,
  getDefaultDeviceName,
  IDENTITY_PBKDF2_ITERATIONS,
  IDENTITY_STORAGE_KEY,
  loadIdentityRecord,
  sanitizeDeviceName,
  saveIdentityRecord,
  unlockIdentity,
} from "../../lib/identity";
export type {
  DecryptedIdentity,
  IdentityKeySource,
  IdentityStorageRecord,
  IdentityWrap,
} from "../../lib/identity";

export type {
  ManifestChangeListener,
  ManifestDatabaseChange,
  ManifestMutation,
  ManifestRecordUpdate,
  OnboardingAuthorizationProbe,
  SyncCommitSummary,
  SyncEngineConfig,
  SyncListener,
  SyncSnapshot,
} from "./syncTypes";

export type { LfsEncryptionMeta, LfsPointerFields } from "./encryption";
export { decryptBinaryChunked, sha256Hex } from "./encryption";

export { shardName, deriveBinaryPointerPath } from "./paths";
