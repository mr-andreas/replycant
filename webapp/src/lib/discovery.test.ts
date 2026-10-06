import { describe, expect, it, vi } from "vitest";
import { DEFAULT_DISCOVERY_BASE, pairingRecordUrl, pollForPairingRecord } from "./discovery";

const slot = "74994ef1ffba0150998d4495f5b97dec";

const record = new Uint8Array([1, 2, 3, 4]);

const okResponse = () =>
  new Response(record, { status: 200, headers: { "content-type": "application/octet-stream" } });
const notFound = () => new Response("not found", { status: 404 });

// Resolves immediately so the polling loop runs at test speed instead of
// waiting out real intervals.
const instantSleep = async () => {};

describe("pairingRecordUrl", () => {
  // The slot is a subdomain rather than a path so a record's address never
  // lands in a request line an intermediary might log.
  it("addresses the record by subdomain", () => {
    expect(pairingRecordUrl(slot)).toBe(`https://${slot}.discovery.replycant.com/`);
    expect(DEFAULT_DISCOVERY_BASE).toBe("https://discovery.replycant.com");
  });

  // The desktop integration suite points this at a plain-HTTP fake on a
  // non-default port, so the override is a whole origin, not just a host.
  it("honours an overridden discovery origin, scheme and port included", () => {
    expect(pairingRecordUrl(slot, "http://discovery.test:18082")).toBe(
      `http://${slot}.discovery.test:18082/`,
    );
  });
});

describe("pollForPairingRecord", () => {
  it("returns the record bytes once it appears", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());

    const result = await pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep });

    expect(Array.from(result)).toEqual([1, 2, 3, 4]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  // A 404 is the expected answer for most of a pairing attempt: it means the
  // operator has not approved the device yet.
  it("keeps polling through not-found responses", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(notFound())
      .mockResolvedValueOnce(notFound())
      .mockResolvedValueOnce(okResponse());

    const result = await pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep });

    expect(Array.from(result)).toEqual([1, 2, 3, 4]);
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  // A device may be pairing over a connection that is still coming up, so a
  // transient network error must not end the attempt.
  it("keeps polling through network errors", async () => {
    const fetchImpl = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce(okResponse());

    const result = await pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep });

    expect(Array.from(result)).toEqual([1, 2, 3, 4]);
  });

  // A misconfigured discovery host would otherwise be indistinguishable from a
  // user who is slow to approve the device, leaving them staring at a spinner.
  it("reports a server error instead of polling on", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("boom", { status: 500 }));

    await expect(pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep })).rejects.toThrow(
      /returned 500/,
    );
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  // The record's own TTL is ten minutes, so waiting past the deadline could
  // only ever return nothing. Failing tells the user to start a fresh attempt.
  it("gives up at the timeout with an actionable message", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(notFound());

    await expect(
      pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep, intervalMs: 10, timeoutMs: 0 }),
    ).rejects.toThrow(/Start pairing again/);
  });

  // Abandoning a pairing attempt has to actually stop the polling, or a
  // discarded attempt keeps consuming reads against its slot.
  it("stops when the attempt is abandoned", async () => {
    const controller = new AbortController();
    const fetchImpl = vi.fn().mockImplementation(async () => {
      controller.abort();
      return notFound();
    });

    await expect(
      pollForPairingRecord({
        slot,
        fetchImpl,
        sleep: instantSleep,
        signal: controller.signal,
      }),
    ).rejects.toThrow(/Aborted/);
  });

  it("does not poll at all when already aborted", async () => {
    const controller = new AbortController();
    controller.abort();
    const fetchImpl = vi.fn();

    await expect(
      pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep, signal: controller.signal }),
    ).rejects.toThrow(/Aborted/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  // A fetch rejection caused by the abort itself must surface as an abort
  // rather than being swallowed and retried forever.
  it("propagates an abort that surfaces as a fetch rejection", async () => {
    const controller = new AbortController();
    const fetchImpl = vi.fn().mockImplementation(async () => {
      controller.abort();
      throw new DOMException("Aborted", "AbortError");
    });

    await expect(
      pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep, signal: controller.signal }),
    ).rejects.toThrow(/Aborted/);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  // The record must never be served from a cache: the read is single-use, so a
  // cached copy would be a record the service already destroyed.
  it("bypasses the HTTP cache", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());

    await pollForPairingRecord({ slot, fetchImpl, sleep: instantSleep });

    expect(fetchImpl.mock.calls[0]?.[1]).toMatchObject({ cache: "no-store", method: "GET" });
  });

  it("waits the configured interval between attempts", async () => {
    const sleep = vi.fn(async (_ms: number) => {});
    const fetchImpl = vi.fn().mockResolvedValueOnce(notFound()).mockResolvedValueOnce(okResponse());

    await pollForPairingRecord({ slot, fetchImpl, sleep, intervalMs: 1_500 });

    expect(sleep).toHaveBeenCalledTimes(1);
    expect(sleep.mock.calls[0][0]).toBe(1_500);
  });
});
