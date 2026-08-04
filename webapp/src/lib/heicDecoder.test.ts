import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

class MockWorker {
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;
  readonly postMessage = vi.fn();
  readonly terminate = vi.fn();

  emitMessage(data: unknown): void {
    this.onmessage?.({ data } as MessageEvent<unknown>);
  }

  emitError(message: string): void {
    this.onerror?.({ message } as ErrorEvent);
  }
}

describe("heicDecoder worker client", () => {
  let workerInstances: MockWorker[];

  beforeEach(() => {
    workerInstances = [];
    const WorkerMock = vi.fn(function MockedWorker() {
      const worker = new MockWorker();
      workerInstances.push(worker);
      return worker;
    });
    vi.stubGlobal("Worker", WorkerMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it("posts decode requests with transferable input and resolves bitmap output", async () => {
    const { decodeHeicToCanvasBitmap } = await import("./heicDecoder");
    const source = new ArrayBuffer(8);
    const promise = decodeHeicToCanvasBitmap(source, 1234);

    expect(workerInstances).toHaveLength(1);
    const worker = workerInstances[0];
    expect(worker.postMessage).toHaveBeenCalledTimes(1);
    const [payload, transfer] = worker.postMessage.mock.calls[0];
    expect(payload).toMatchObject({ type: "decode", maxPixels: 1234 });
    expect(transfer).toEqual([source]);

    const pixels = new Uint8ClampedArray([1, 2, 3, 4]).buffer;
    worker.emitMessage({
      type: "decoded",
      requestId: 1,
      width: 1,
      height: 1,
      pixels,
    });
    await expect(promise).resolves.toEqual({
      width: 1,
      height: 1,
      pixels: new Uint8ClampedArray([1, 2, 3, 4]),
    });
    expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("maps worker decode errors into HeicDecodeError", async () => {
    const { decodeHeicToCanvasBitmap, HeicDecodeError } = await import("./heicDecoder");
    const promise = decodeHeicToCanvasBitmap(new ArrayBuffer(4));

    expect(workerInstances).toHaveLength(1);
    const worker = workerInstances[0];
    worker.emitMessage({
      type: "decode-error",
      requestId: 1,
      code: "image-too-large",
      message: "too large",
    });

    await expect(promise).rejects.toBeInstanceOf(HeicDecodeError);
    await expect(promise).rejects.toMatchObject({
      code: "image-too-large",
      message: "too large",
    });
    expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("terminates an in-flight decode when aborted", async () => {
    const { decodeHeicToCanvasBitmap } = await import("./heicDecoder");
    const controller = new AbortController();
    const promise = decodeHeicToCanvasBitmap(new ArrayBuffer(4), 50_000_000, controller.signal);

    expect(workerInstances).toHaveLength(1);
    const worker = workerInstances[0];
    controller.abort();

    await expect(promise).rejects.toMatchObject({ name: "AbortError" });
    expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("preempts a previous decode when a newer request arrives", async () => {
    const { decodeHeicToCanvasBitmap } = await import("./heicDecoder");
    const first = decodeHeicToCanvasBitmap(new ArrayBuffer(4));
    expect(workerInstances).toHaveLength(1);
    const firstWorker = workerInstances[0];

    const second = decodeHeicToCanvasBitmap(new ArrayBuffer(6));
    expect(workerInstances).toHaveLength(2);
    const secondWorker = workerInstances[1];

    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    expect(firstWorker.terminate).toHaveBeenCalledTimes(1);

    secondWorker.emitMessage({
      type: "decoded",
      requestId: 2,
      width: 2,
      height: 1,
      pixels: new Uint8ClampedArray([1, 2, 3, 4, 5, 6, 7, 8]).buffer,
    });
    await expect(second).resolves.toMatchObject({ width: 2, height: 1 });
  });
});
