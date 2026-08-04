declare module "libheif-js/wasm-bundle" {
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

  const heifModule: HeifWasm;
  export default heifModule;
}
