interface HeifDecodedImage {
  get_width(): number;
  get_height(): number;
  display(data: ImageData, callback: (output: ImageData | null) => void): void;
}

interface HeifDecoder {
  decode(data: Uint8Array): HeifDecodedImage[];
}

interface HeifWasm {
  HeifDecoder: new () => HeifDecoder;
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

interface HeicDecodeFailurePayload {
  code: HeicDecodeErrorCode;
  message: string;
}

// Keeps this file type-safe under the app tsconfig, which also includes DOM globals.
interface WorkerMessagePort {
  postMessage(message: HeicDecodeSuccessMessage, transfer: Transferable[]): void;
  postMessage(message: HeicDecodeFailureMessage): void;
}

let heifModulePromise: Promise<HeifWasm> | null = null;
const workerPort = globalThis as unknown as WorkerMessagePort;

// Loads the WASM decoder once per worker so decode requests avoid repeated setup.
const getHeifModule = async (): Promise<HeifWasm> => {
  if (!heifModulePromise) {
    heifModulePromise = import("libheif-js/wasm-bundle")
      .then((imported) => (imported.default ?? imported) as HeifWasm)
      .catch((error) => {
        throw {
          code: "decoder-unavailable",
          message: "Failed to initialize HEIC decoder.",
          cause: error,
        };
      });
  }
  return heifModulePromise;
};

// Decodes one HEIC payload and returns raw RGBA bytes for canvas painting.
const decodeBuffer = async (
  buffer: ArrayBuffer,
  maxPixels: number,
): Promise<{ width: number; height: number; pixels: Uint8ClampedArray }> => {
  const heif = await getHeifModule();
  const decoder = new heif.HeifDecoder();
  const images = decoder.decode(new Uint8Array(buffer));
  if (images.length < 1) {
    throw { code: "invalid-image", message: "HEIC does not contain a decodable image." } satisfies HeicDecodeFailurePayload;
  }
  const image = images[0];
  const width = image.get_width();
  const height = image.get_height();
  if (width * height > maxPixels) {
    throw { code: "image-too-large", message: "HEIC exceeds supported fullscreen dimensions." } satisfies HeicDecodeFailurePayload;
  }

  const imageData = new ImageData(width, height);
  await new Promise<void>((resolve, reject) => {
    image.display(imageData, (output) => {
      if (!output) {
        reject(new Error("HEIC processing error."));
        return;
      }
      resolve();
    });
  });
  return { width, height, pixels: new Uint8ClampedArray(imageData.data) };
};

// Serves decode requests from the main thread and returns typed success/failure payloads.
globalThis.addEventListener("message", (event: MessageEvent<HeicDecodeRequestMessage>) => {
  if (event.data?.type !== "decode") return;
  const { requestId, buffer, maxPixels } = event.data;
  void (async () => {
    try {
      const decoded = await decodeBuffer(buffer, maxPixels);
      const pixels = new ArrayBuffer(decoded.pixels.byteLength);
      new Uint8ClampedArray(pixels).set(decoded.pixels);
      const success: HeicDecodeSuccessMessage = {
        type: "decoded",
        requestId,
        width: decoded.width,
        height: decoded.height,
        pixels,
      };
      workerPort.postMessage(success, [success.pixels]);
    } catch (error) {
      const failure: HeicDecodeFailureMessage = {
        type: "decode-error",
        requestId,
        code: "invalid-image",
        message: "Failed to decode HEIC image.",
      };
      if (typeof error === "object" && error !== null) {
        const code = (error as { code?: string }).code;
        const message = (error as { message?: string }).message;
        if (code === "image-too-large" || code === "invalid-image" || code === "decoder-unavailable") {
          failure.code = code;
        }
        if (typeof message === "string" && message.length > 0) {
          failure.message = message;
        }
      }
      workerPort.postMessage(failure);
    }
  })();
});
