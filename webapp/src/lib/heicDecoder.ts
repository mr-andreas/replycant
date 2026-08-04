// Describes decode failures so fullscreen can choose server fallback paths predictably.
export class HeicDecodeError extends Error {
  code: "decoder-unavailable" | "invalid-image" | "image-too-large";

  constructor(
    message: string,
    code: "decoder-unavailable" | "invalid-image" | "image-too-large",
    options?: { cause?: unknown },
  ) {
    super(message);
    this.name = "HeicDecodeError";
    this.code = code;
    this.cause = options?.cause;
  }
}

// Carries decoded pixel content in a canvas-ready shape without forcing JPEG re-encoding.
export interface HeicCanvasBitmap {
  width: number;
  height: number;
  pixels: Uint8ClampedArray;
}

type HeicDecodeErrorCode = "decoder-unavailable" | "invalid-image" | "image-too-large";

interface HeicDecodeRequestMessage {
  type: "decode";
  requestId: number;
  buffer: ArrayBuffer;
  maxPixels: number;
}

interface HeicDecodeSuccessMessage {
  type: "decoded";
  requestId: number;
  width: number;
  height: number;
  pixels: ArrayBuffer;
}

interface HeicDecodeFailureMessage {
  type: "decode-error";
  requestId: number;
  code: HeicDecodeErrorCode;
  message: string;
}

interface ActiveDecode {
  requestId: number;
  worker: Worker;
  reject: (reason?: unknown) => void;
  removeAbortListener: () => void;
}

let nextRequestId = 1;
let activeDecode: ActiveDecode | null = null;

// Builds a stable abort-shaped error so cancellation paths are easy to detect.
const createAbortError = (message: string): Error => {
  const error = new Error(message);
  error.name = "AbortError";
  return error;
};

// Rejects and tears down the currently running decode so new requests stay responsive.
const cancelActiveDecode = (reason: string): void => {
  if (!activeDecode) return;
  const current = activeDecode;
  activeDecode = null;
  current.removeAbortListener();
  current.worker.terminate();
  current.reject(createAbortError(reason));
};

// Decodes the first HEIC image frame into RGBA pixels for canvas rendering in fullscreen mode.
export const decodeHeicToCanvasBitmap = async (
  buffer: ArrayBuffer,
  maxPixels = 50_000_000,
  signal?: AbortSignal,
): Promise<HeicCanvasBitmap> => {
  if (signal?.aborted) {
    throw createAbortError("HEIC decode aborted.");
  }
  cancelActiveDecode("HEIC decode superseded by a newer request.");

  return new Promise<HeicCanvasBitmap>((resolve, reject) => {
    const requestId = nextRequestId++;
    const worker = new Worker(new URL("./heicDecodeWorker.ts", import.meta.url), { type: "module" });

    const removeAbortListener = (() => {
      if (!signal) return () => undefined;
      const onAbort = () => {
        if (!activeDecode || activeDecode.requestId !== requestId) return;
        cancelActiveDecode("HEIC decode aborted.");
      };
      signal.addEventListener("abort", onAbort, { once: true });
      return () => signal.removeEventListener("abort", onAbort);
    })();

    const finalize = (): void => {
      removeAbortListener();
      worker.onmessage = null;
      worker.onerror = null;
      worker.terminate();
      if (activeDecode?.requestId === requestId) {
        activeDecode = null;
      }
    };

    activeDecode = { requestId, worker, reject, removeAbortListener };

    worker.onmessage = (event: MessageEvent<HeicDecodeSuccessMessage | HeicDecodeFailureMessage>) => {
      const message = event.data;
      if (!message || message.requestId !== requestId) return;
      if (message.type === "decoded") {
        finalize();
        resolve({
          width: message.width,
          height: message.height,
          pixels: new Uint8ClampedArray(message.pixels),
        });
        return;
      }
      finalize();
      reject(new HeicDecodeError(message.message, message.code));
    };

    worker.onerror = (event: ErrorEvent) => {
      finalize();
      reject(
        new HeicDecodeError("Failed to initialize HEIC decoder.", "decoder-unavailable", {
          cause: event.message,
        }),
      );
    };

    try {
      const payload: HeicDecodeRequestMessage = {
        type: "decode",
        requestId,
        buffer,
        maxPixels,
      };
      worker.postMessage(payload, [buffer]);
    } catch (error) {
      finalize();
      if (error instanceof HeicDecodeError) {
        reject(error);
        return;
      }
      reject(
        new HeicDecodeError("Failed to initialize HEIC decoder.", "decoder-unavailable", {
          cause: error,
        }),
      );
    }
  });
};

// Allows callers to cancel an in-flight decode when navigation invalidates its output.
export const cancelHeicDecode = (): void => {
  cancelActiveDecode("HEIC decode aborted.");
};
