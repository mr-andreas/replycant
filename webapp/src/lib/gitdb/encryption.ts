// Re-exports all encryption primitives from their canonical gitdb-owned location so
// existing consumers continue to compile without import path changes during migration.
export {
  decryptAgeEnvelope,
  decryptBinaryChunked,
  decryptManifestBody,
  importAes256Key,
  isEncryptedManifest,
  loadAndUnwrapKEK,
  parseEncryptedManifestHeader,
  parseLfsPointer,
  sha256Hex,
  toLfsEncryptionMeta,
  unwrapDEK,
} from "../../modules/gitdb/encryption";

export type {
  EncryptedManifestPayload,
  LfsEncryptionMeta,
  LfsPointerFields,
} from "../../modules/gitdb/encryption";
