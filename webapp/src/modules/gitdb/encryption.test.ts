import { describe, expect, it } from "vitest";
import {
  CHUNK_SIZE,
  chunkAad,
  chunkNonce,
  decryptBinaryChunked,
  parseLfsPointer,
  toLfsEncryptionMeta,
  unwrapDEK,
} from "./encryption";
import {
  encryptBinaryChunked,
  importTestKek,
  TEST_DEK_RAW,
  TEST_KEK_RAW,
  wrapTestDEK,
} from "./testEncryption";

// Fixed material shared with Go/Swift golden vectors so framing cannot drift.
const GOLDEN_DEK = new Uint8Array(32).fill(0x11);
const GOLDEN_PLAINTEXT = (() => {
  const bytes = new Uint8Array(CHUNK_SIZE + 7);
  bytes.fill(0x42, 0, CHUNK_SIZE);
  bytes.set(new TextEncoder().encode("tail-7!"), CHUNK_SIZE);
  return bytes;
})();
const GOLDEN_CIPHERTEXT_SHA256 =
  "a8300613749c6d09bb332763ed5ea3c547aee4f86d85b374483fb9c2af38e053";

// Narrows Uint8Array to DOM BufferSource for strict TS lib compatibility.
const asBufferSource = (bytes: Uint8Array): BufferSource => bytes as unknown as BufferSource;

describe("authenticated chunk framing", () => {
  // Pins the repo-wide constant chosen after seek/throughput measurement.
  it("uses a 64 KiB chunk size", () => {
    expect(CHUNK_SIZE).toBe(65536);
  });

  // Keeps nonce layout aligned with iOS EncryptionUtils.nonceForChunk.
  it("derives index nonces as 0||u64BE(index)", () => {
    expect(Array.from(chunkNonce(0))).toEqual(Array(12).fill(0));
    const nonce1 = chunkNonce(1);
    expect(nonce1[11]).toBe(1);
    expect(nonce1.slice(0, 11)).toEqual(new Uint8Array(11));
  });

  // Verifies AAD layout so reorder/truncation changes fail authentication.
  it("binds chunk AAD to index and last-chunk flag", () => {
    const last = chunkAad(2, true);
    const notLast = chunkAad(2, false);
    expect(new TextDecoder().decode(last.slice(0, "replycant-lfs-chunk-v1".length))).toBe(
      "replycant-lfs-chunk-v1",
    );
    expect(last[last.length - 1]).toBe(1);
    expect(notLast[notLast.length - 1]).toBe(0);
    expect(last).not.toEqual(notLast);
  });

  // Verifies v2 framing roundtrips and uses 16-byte per-chunk overhead.
  it("roundtrips chunked encrypt/decrypt with 16-byte overhead", async () => {
    const plaintext = new TextEncoder().encode("payload-".repeat(9000));
    const encrypted = await encryptBinaryChunked(plaintext, TEST_DEK_RAW);
    const n = Math.ceil(plaintext.length / CHUNK_SIZE);
    expect(encrypted.length).toBe(plaintext.length + n * 16);
    const roundtrip = new Uint8Array(await decryptBinaryChunked(encrypted.buffer, TEST_DEK_RAW));
    expect(Buffer.from(roundtrip)).toEqual(Buffer.from(plaintext));
  });

  // Keeps empty objects free of a spurious authenticated frame.
  it("encrypts empty plaintext as zero chunks", async () => {
    const encrypted = await encryptBinaryChunked(new Uint8Array(0), TEST_DEK_RAW);
    expect(encrypted.length).toBe(0);
    const roundtrip = new Uint8Array(await decryptBinaryChunked(encrypted.buffer, TEST_DEK_RAW));
    expect(roundtrip.length).toBe(0);
  });

  // Ensures swapping frames fails because index-derived nonces and AAD bind position.
  it("rejects reordered chunks", async () => {
    const encrypted = await encryptBinaryChunked(GOLDEN_PLAINTEXT, GOLDEN_DEK);
    const frame0 = CHUNK_SIZE + 16;
    const swapped = new Uint8Array(encrypted.length);
    swapped.set(encrypted.slice(frame0), 0);
    swapped.set(encrypted.slice(0, frame0), encrypted.length - frame0);
    await expect(decryptBinaryChunked(swapped.buffer, GOLDEN_DEK)).rejects.toThrow();
  });

  // Ensures trailing truncation fails because the new last frame was sealed with isLast=0.
  it("rejects dropped last chunk", async () => {
    const encrypted = await encryptBinaryChunked(GOLDEN_PLAINTEXT, GOLDEN_DEK);
    const truncated = encrypted.slice(0, CHUNK_SIZE + 16);
    await expect(decryptBinaryChunked(truncated.buffer, GOLDEN_DEK)).rejects.toThrow();
  });

  // Binds wrapped DEKs to kek-epoch so pointer metadata cannot move across epochs.
  it("rejects DEK unwrap with the wrong epoch", async () => {
    const wrapped = await wrapTestDEK(TEST_DEK_RAW, TEST_KEK_RAW, 3);
    const kek = await importTestKek(TEST_KEK_RAW);
    const dek = await unwrapDEK(wrapped, kek, 3);
    expect(dek).toEqual(TEST_DEK_RAW);
    await expect(unwrapDEK(wrapped, kek, 4)).rejects.toThrow();
  });

  // Pins the ciphertext digest shared with Go and Swift.
  it("matches the cross-platform golden ciphertext digest", async () => {
    const encrypted = await encryptBinaryChunked(GOLDEN_PLAINTEXT, GOLDEN_DEK);
    expect(encrypted.length).toBe(CHUNK_SIZE + 7 + 2 * 16);
    const digest = await crypto.subtle.digest("SHA-256", asBufferSource(encrypted));
    const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    expect(hex).toBe(GOLDEN_CIPHERTEXT_SHA256);
  });

  // Chunk size leaves the pointer wire format entirely.
  it("parses pointers without chunk-size and builds encryption meta", () => {
    const pointer = parseLfsPointer(
      [
        "version https://git-lfs.github.com/spec/v1",
        "oid sha256:abc123",
        "size 10",
        "x-replycant-kek-epoch 2",
        "x-replycant-wrapped-dek wrapped",
        "",
      ].join("\n"),
    );
    expect(pointer).toEqual({
      oid: "abc123",
      size: 10,
      kekEpoch: 2,
      wrappedDek: "wrapped",
    });
    expect(
      toLfsEncryptionMeta({
        ...pointer,
        dekBase64: "ZGVr",
      }),
    ).toEqual({
      encryptedOid: "abc123",
      wrappedDek: "wrapped",
      kekEpoch: 2,
      dekBase64: "ZGVr",
    });
  });

});
