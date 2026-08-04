import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createGitdbWorker } from "./gitdbWorkerClient";

type WorkerMessageListener = (event: MessageEvent) => void;
type WorkerErrorListener = (event: ErrorEvent) => void;

// Tracks one mock worker instance so tests can assert startup retries and teardown.
class MockWorker {
  static instances: MockWorker[] = [];
  static readyOnInitAttemptIndexes = new Set<number>([1]);

  readonly index: number;
  readonly postedMessages: unknown[] = [];
  readonly messageListeners: WorkerMessageListener[] = [];
  readonly errorListeners: WorkerErrorListener[] = [];
  terminated = false;

  constructor() {
    this.index = MockWorker.instances.length;
    MockWorker.instances.push(this);
  }

  // Captures handlers so tests can emit synthetic worker events deterministically.
  addEventListener(type: string, listener: EventListener): void {
    if (type === "message") this.messageListeners.push(listener as WorkerMessageListener);
    if (type === "error") this.errorListeners.push(listener as WorkerErrorListener);
  }

  // Records outbound messages and auto-acks ready for configured startup attempts.
  postMessage(message: unknown): void {
    this.postedMessages.push(message);
    const payload = message as { type?: string };
    if (payload.type === "init" && MockWorker.readyOnInitAttemptIndexes.has(this.index)) {
      this.emitMessage({ type: "ready" });
    }
  }

  // Reflects worker shutdown so tests can verify timed-out attempts are terminated.
  terminate(): void {
    this.terminated = true;
  }

  // Delivers an outbound worker payload to registered message listeners.
  emitMessage(data: unknown): void {
    const event = { data } as MessageEvent;
    for (const listener of this.messageListeners) {
      listener(event);
    }
  }
}

describe("createGitdbWorker startup retries", () => {
  const originalWorker = globalThis.Worker;

  // Replaces Worker with a deterministic mock so startup timing behavior is testable.
  beforeEach(() => {
    MockWorker.instances = [];
    MockWorker.readyOnInitAttemptIndexes = new Set<number>([1]);
    vi.useFakeTimers();
    globalThis.Worker = MockWorker as unknown as typeof Worker;
  });

  // Restores global Worker/timers so other suites run with real browser primitives.
  afterEach(() => {
    vi.useRealTimers();
    globalThis.Worker = originalWorker;
  });

  it("terminates a stalled worker and succeeds on one retry", async () => {
    const client = createGitdbWorker();
    const initializePromise = client.initialize();

    await vi.advanceTimersByTimeAsync(8_000);
    await initializePromise;

    expect(MockWorker.instances).toHaveLength(2);
    expect(MockWorker.instances[0].terminated).toBe(true);
    expect(MockWorker.instances[1].terminated).toBe(false);
  });

  it("waits for the in-flight ready handshake when initialize is called twice", async () => {
    MockWorker.readyOnInitAttemptIndexes = new Set<number>();
    const client = createGitdbWorker();
    const firstInitialize = client.initialize();
    let secondResolved = false;
    const secondInitialize = client.initialize().then(() => {
      secondResolved = true;
    });

    await Promise.resolve();

    expect(MockWorker.instances).toHaveLength(1);
    expect(secondResolved).toBe(false);

    MockWorker.instances[0].emitMessage({ type: "ready" });
    await Promise.all([firstInitialize, secondInitialize]);

    expect(secondResolved).toBe(true);
  });

  it("rejects after timeout when retry also stalls", async () => {
    MockWorker.readyOnInitAttemptIndexes = new Set<number>();
    const client = createGitdbWorker();
    const initializePromise = client.initialize();
    const initializeRejected = expect(initializePromise).rejects.toThrow("Sync worker ready timeout.");

    await vi.advanceTimersByTimeAsync(16_000);

    await initializeRejected;
    expect(MockWorker.instances).toHaveLength(2);
    expect(MockWorker.instances[0].terminated).toBe(true);
    expect(MockWorker.instances[1].terminated).toBe(true);
  });
});
