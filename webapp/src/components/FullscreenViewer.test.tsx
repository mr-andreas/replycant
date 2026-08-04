import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { decodeHeicToCanvasBitmap } from "../lib/heicDecoder";
import { fetchAndCacheAuthenticatedMedia } from "../lib/preloadMedia";
import { computeContainSize, FullscreenViewer } from "./FullscreenViewer";

vi.mock("../lib/heicDecoder", () => ({
  decodeHeicToCanvasBitmap: vi.fn(),
}));

vi.mock("../lib/preloadMedia", () => ({
  fetchAndCacheAuthenticatedMedia: vi.fn(),
}));

vi.mock("../lib/gitdb/encryption", () => ({
  decryptBinaryChunked: vi.fn(async (bytes: ArrayBuffer) => bytes),
  sha256Hex: vi.fn(async () => "hash-1"),
}));

const testEncryption = {
  encryptedOid: "lfs-1",
  wrappedDek: "wrapped",
  kekEpoch: 1,
  dekBase64: "ZGVr",
};

const items = [
  {
    key: "a/1",
    dayKey: "2026-01-02",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-02T00:00:00Z",
    mediaType: "photo",
    sha256: "hash-1",
    filesize: 5242880,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-1.jpg",
    intermediateViewerUrl: "/mid-1.jpg",
    viewerUrl: "/full-1.jpg",
    downloadUrl: "/api/lfs/objects/lfs-1",
    originalFileName: "IMG_0001.jpg",
    encryption: testEncryption,
    thumbnailEncryption: { ...testEncryption, encryptedOid: "thumb-1" },
  },
  {
    key: "a/2",
    dayKey: "2026-01-03",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-03T00:00:00Z",
    mediaType: "photo",
    sha256: "hash-2",
    filesize: 2621440,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-2.jpg",
    intermediateViewerUrl: "/mid-2.jpg",
    viewerUrl: "/full-2.jpg",
    downloadUrl: "/api/lfs/objects/lfs-2",
    originalFileName: "IMG_0002.jpg",
    encryption: { ...testEncryption, encryptedOid: "lfs-2" },
    thumbnailEncryption: { ...testEncryption, encryptedOid: "thumb-2" },
  },
];

describe("computeContainSize", () => {
  it("scales an image up so it fills the larger viewport while preserving aspect ratio", () => {
    // A small image inside a much larger viewport should grow until the
    // limiting dimension touches the edge, not stay at its natural size.
    const fit = computeContainSize({ width: 400, height: 300 }, { width: 1600, height: 1200 });
    expect(fit).toEqual({ width: 1600, height: 1200 });
  });

  it("limits scaling to the constraining viewport dimension", () => {
    const fit = computeContainSize({ width: 400, height: 200 }, { width: 1000, height: 1000 });
    expect(fit).toEqual({ width: 1000, height: 500 });
  });

  it("shrinks an oversized image to fit", () => {
    const fit = computeContainSize({ width: 4000, height: 2000 }, { width: 1000, height: 1000 });
    expect(fit).toEqual({ width: 1000, height: 500 });
  });

  it("returns null when dimensions are unknown so the CSS fallback applies", () => {
    expect(computeContainSize({ width: 0, height: 0 }, { width: 100, height: 100 })).toBeNull();
    expect(computeContainSize({ width: 100, height: 100 }, { width: 0, height: 0 })).toBeNull();
  });
});

describe("FullscreenViewer", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Keeps authenticated thumbnail tests deterministic in jsdom where the
    // viewport observer API is not available by default.
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    );
  });

  it("downloads the original media when download button is clicked", async () => {
    const objectUrl = "blob:download-url";
    const blob = new Blob(["media"], { type: "image/jpeg" });
    vi.mocked(fetchAndCacheAuthenticatedMedia).mockResolvedValue(blob);
    const createObjectUrlSpy = vi.spyOn(URL, "createObjectURL").mockReturnValue(objectUrl);
    const revokeObjectUrlSpy = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    const anchorClickSpy = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);

    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    fireEvent.click(screen.getByLabelText("Download"));

    await waitFor(() => {
      expect(fetchAndCacheAuthenticatedMedia).toHaveBeenCalledWith({
        src: "/api/lfs/objects/lfs-1",
        headers: { authorization: "test" },
        encryption: testEncryption,
        expectedSha256: "hash-1",
      });
    });
    expect(createObjectUrlSpy).toHaveBeenCalledWith(blob);
    expect(anchorClickSpy).toHaveBeenCalled();
    expect(revokeObjectUrlSpy).toHaveBeenCalledWith(objectUrl);
  });

  it("disables the download button while a download is in flight", async () => {
    let resolveBlob!: (blob: Blob) => void;
    const pendingBlob = new Promise<Blob>((resolve) => {
      resolveBlob = resolve;
    });
    vi.mocked(fetchAndCacheAuthenticatedMedia).mockReturnValue(pendingBlob);

    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    const downloadButton = screen.getByLabelText("Download");
    fireEvent.click(downloadButton);
    expect(downloadButton).toBeDisabled();

    resolveBlob(new Blob(["done"], { type: "image/jpeg" }));
    await waitFor(() => {
      expect(downloadButton).not.toBeDisabled();
    });
  });

  it("renders thumbnail first for progressive image loading", () => {
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );
    const image = screen.getByRole("img", { name: "2026-01-02T00:00:00Z" });
    expect(image).toHaveAttribute("src", "/thumb-1.jpg");
  });

  it("navigates with keyboard arrows and closes on escape", () => {
    const onClose = vi.fn();
    const onChange = vi.fn();
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={onClose}
        onChange={onChange}
        mtlsHeaders={null}
      />,
    );

    fireEvent.keyDown(window, { key: "ArrowRight" });
    fireEvent.keyDown(window, { key: "Escape" });

    expect(onChange).toHaveBeenCalledWith(1);
    expect(onClose).toHaveBeenCalled();
  });

  it("crossfades backdrop layers when navigation changes the active item", async () => {
    const ViewerHarness = () => {
      const [index, setIndex] = useState(0);
      return (
        <FullscreenViewer
          itemCount={items.length}
          loadedOffset={0}
          loadedItems={items}
          index={index}
          onClose={vi.fn()}
          onChange={(nextIndex) => setIndex(nextIndex)}
          mtlsHeaders={null}
        />
      );
    };

    const { container } = render(<ViewerHarness />);

    await waitFor(() => {
      const initialBackdrops = Array.from(container.querySelectorAll(".viewer-backdrop")) as HTMLElement[];
      expect(initialBackdrops).toHaveLength(2);
      const initialVisibleBackdrop = initialBackdrops.find((backdrop) => !backdrop.classList.contains("viewer-backdrop-hidden"));
      const initialHiddenBackdrop = initialBackdrops.find((backdrop) => backdrop.classList.contains("viewer-backdrop-hidden"));
      expect(initialVisibleBackdrop?.style.backgroundImage).toContain("/thumb-1.jpg");
      expect(initialHiddenBackdrop?.style.backgroundImage).toBe("");
    });

    fireEvent.click(screen.getByRole("button", { name: "Next" }));

    await waitFor(() => {
      const navigatedBackdrops = Array.from(container.querySelectorAll(".viewer-backdrop")) as HTMLElement[];
      expect(navigatedBackdrops).toHaveLength(2);
      const visibleBackdrop = navigatedBackdrops.find((backdrop) => !backdrop.classList.contains("viewer-backdrop-hidden"));
      const hiddenBackdrop = navigatedBackdrops.find((backdrop) => backdrop.classList.contains("viewer-backdrop-hidden"));
      expect(visibleBackdrop?.style.backgroundImage).toContain("/thumb-2.jpg");
      expect(hiddenBackdrop?.style.backgroundImage).toContain("/thumb-1.jpg");
    });
  });

  it("clamps repeated keyboard navigation one step beyond sparse boundary", () => {
    const onChange = vi.fn();
    const ViewerHarness = () => {
      const [index, setIndex] = useState(1);
      return (
        <FullscreenViewer
          itemCount={10}
          loadedOffset={0}
          loadedItems={items}
          index={index}
          onClose={vi.fn()}
          onChange={(nextIndex) => {
            onChange(nextIndex);
            setIndex(nextIndex);
          }}
          mtlsHeaders={null}
        />
      );
    };

    render(<ViewerHarness />);

    fireEvent.keyDown(window, { key: "ArrowRight" });
    fireEvent.keyDown(window, { key: "ArrowRight" });

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith(2);
    expect(screen.getByText("Loading media...")).toBeInTheDocument();
  });

  it("allows next-button navigation to cross sparse boundary by one item", () => {
    const onChange = vi.fn();
    const ViewerHarness = () => {
      const [index, setIndex] = useState(1);
      return (
        <FullscreenViewer
          itemCount={10}
          loadedOffset={0}
          loadedItems={items}
          index={index}
          onClose={vi.fn()}
          onChange={(nextIndex) => {
            onChange(nextIndex);
            setIndex(nextIndex);
          }}
          mtlsHeaders={null}
        />
      );
    };

    render(<ViewerHarness />);

    fireEvent.click(screen.getByRole("button", { name: "Next" }));

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith(2);
    expect(screen.getByText("Loading media...")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Next" })).toBeNull();
  });

  it("keeps viewer open with loading placeholder when navigation points outside loaded window", () => {
    // Sparse timeline windows can temporarily make the selected index unresolved.
    // The viewer must still render safely while data catches up.
    const { rerender } = render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    expect(() => {
      rerender(
        <FullscreenViewer
          itemCount={items.length + 2}
          loadedOffset={0}
          loadedItems={items}
          index={3}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={{ authorization: "test" }}
        />,
      );
    }).not.toThrow();
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByText("Loading media...")).toBeInTheDocument();
  });

  it("uses direct-play video src with decryptd query params for encrypted videos", async () => {
    const { container } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            mediaType: "video",
            viewerUrl: "/api/decryptd/objects/video-1",
            encryption: {
              encryptedOid: "video-1",
              wrappedDek: "wrapped",
              kekEpoch: 1,
              dekBase64: "a+b/c=",
            },
            isHeic: false,
            heicOriginalUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    const video = container.querySelector("video");
    expect(video).not.toBeNull();
    expect(video).toHaveAttribute("controls");
    await waitFor(() => {
      expect(video).toHaveAttribute(
        "src",
        "/api/decryptd/objects/video-1?dek=a%2Bb%2Fc%3D",
      );
    });
  });

  it("does not reassign direct-play video src when only encryption object identity changes", async () => {
    const initialItem = {
      ...items[0],
      mediaType: "video",
      viewerUrl: "/api/decryptd/objects/video-1",
      encryption: {
        encryptedOid: "video-1",
        wrappedDek: "wrapped",
        kekEpoch: 1,
        dekBase64: "a+b/c=",
      },
      isHeic: false,
      heicOriginalUrl: null,
    };
    const nextItem = {
      ...initialItem,
      encryption: { ...initialItem.encryption },
    };
    const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
    if (!srcDescriptor?.set || !srcDescriptor.get) {
      throw new Error("HTMLMediaElement src descriptor is unavailable in this runtime");
    }
    const srcSetSpy = vi.fn();
    Object.defineProperty(HTMLMediaElement.prototype, "src", {
      configurable: true,
      get(this: HTMLMediaElement) {
        return srcDescriptor.get!.call(this);
      },
      set(this: HTMLMediaElement, value: string) {
        srcSetSpy(value);
        srcDescriptor.set!.call(this, value);
      },
    });
    try {
      const { rerender } = render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[initialItem]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );
      await waitFor(() => {
        expect(srcSetSpy).toHaveBeenCalledWith("/api/decryptd/objects/video-1?dek=a%2Bb%2Fc%3D");
      });
      srcSetSpy.mockClear();

      rerender(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[nextItem]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );
      expect(srcSetSpy).not.toHaveBeenCalled();
    } finally {
      Object.defineProperty(HTMLMediaElement.prototype, "src", srcDescriptor);
    }
  });

  it("reassigns direct-play video src when dek changes", async () => {
    const initialItem = {
      ...items[0],
      mediaType: "video",
      viewerUrl: "/api/decryptd/objects/video-1",
      encryption: {
        encryptedOid: "video-1",
        wrappedDek: "wrapped",
        kekEpoch: 1,
        dekBase64: "a+b/c=",
      },
      isHeic: false,
      heicOriginalUrl: null,
    };
    const rotatedDekItem = {
      ...initialItem,
      encryption: {
        ...initialItem.encryption,
        dekBase64: "rotated==",
      },
    };
    const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
    if (!srcDescriptor?.set || !srcDescriptor.get) {
      throw new Error("HTMLMediaElement src descriptor is unavailable in this runtime");
    }
    const srcSetSpy = vi.fn();
    Object.defineProperty(HTMLMediaElement.prototype, "src", {
      configurable: true,
      get(this: HTMLMediaElement) {
        return srcDescriptor.get!.call(this);
      },
      set(this: HTMLMediaElement, value: string) {
        srcSetSpy(value);
        srcDescriptor.set!.call(this, value);
      },
    });
    try {
      const { rerender } = render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[initialItem]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );
      await waitFor(() => {
        expect(srcSetSpy).toHaveBeenCalledWith("/api/decryptd/objects/video-1?dek=a%2Bb%2Fc%3D");
      });
      srcSetSpy.mockClear();

      rerender(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[rotatedDekItem]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );
      await waitFor(() => {
        expect(srcSetSpy).toHaveBeenCalledWith("/api/decryptd/objects/video-1?dek=rotated%3D%3D");
      });
    } finally {
      Object.defineProperty(HTMLMediaElement.prototype, "src", srcDescriptor);
    }
  });

  it("loads an LFS video backdrop through authenticated media instead of a raw CSS URL", async () => {
    const blob = new Blob(["thumb"], { type: "image/jpeg" });
    vi.mocked(fetchAndCacheAuthenticatedMedia).mockResolvedValue(blob);
    const createObjectUrlSpy = vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:video-backdrop");
    const revokeObjectUrlSpy = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    const { container, unmount } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            mediaType: "video",
            thumbnailUrl: "/api/lfs/objects/video-thumb",
            viewerUrl: "/api/decryptd/objects/video-1",
            thumbnailEncryption: { ...testEncryption, encryptedOid: "video-thumb" },
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      expect(fetchAndCacheAuthenticatedMedia).toHaveBeenCalledWith({
        src: "/api/lfs/objects/video-thumb",
        headers: { authorization: "test" },
        encryption: { ...testEncryption, encryptedOid: "video-thumb" },
        expectedSha256: undefined,
        signal: expect.any(AbortSignal),
      });
    });

    const backdropLayers = Array.from(container.querySelectorAll(".viewer-backdrop")) as HTMLElement[];
    expect(createObjectUrlSpy).toHaveBeenCalledWith(blob);
    await waitFor(() => {
      const visibleBackdrop = backdropLayers.find((backdrop) => !backdrop.classList.contains("viewer-backdrop-hidden"));
      expect(visibleBackdrop?.style.backgroundImage).toContain("blob:video-backdrop");
      expect(visibleBackdrop?.style.backgroundImage).not.toContain("/api/lfs/objects/video-thumb");
    });
    unmount();
    await waitFor(() => {
      expect(revokeObjectUrlSpy).toHaveBeenCalledWith("blob:video-backdrop");
    });
  });

  it("shows a thumbnail poster with spinner until video can play", () => {
    const { container } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            mediaType: "video",
            thumbnailUrl: "/api/lfs/objects/video-thumb",
            viewerUrl: "/api/decryptd/objects/video-1",
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    const poster = container.querySelector(".viewer-video-poster");
    const spinner = container.querySelector(".viewer-video-spinner");
    const video = container.querySelector("video");
    expect(poster).not.toBeNull();
    expect(spinner).not.toBeNull();
    expect(video).not.toBeNull();
    expect(poster).not.toHaveClass("viewer-video-poster-hidden");

    fireEvent.canPlay(video as HTMLVideoElement);
    expect(poster).toHaveClass("viewer-video-poster-hidden");
  });

  it("keeps fullscreen video sizing capped instead of forcing full-stage dimensions", () => {
    // Locks the CSS contract that prevents portrait videos from growing taller
    // than the viewport when their intrinsic aspect ratio is applied.
    const css = readFileSync(resolve(__dirname, "../styles.css"), "utf8");
    const videoRuleMatch = css.match(/\.viewer-video\s*\{[\s\S]*?\}/);
    expect(videoRuleMatch).not.toBeNull();

    const videoRule = videoRuleMatch![0];
    expect(videoRule).toContain("max-width: 100%");
    expect(videoRule).toContain("max-height: 100%");
    expect(videoRule).toContain("width: auto");
    expect(videoRule).toContain("height: auto");
    expect(videoRule).not.toMatch(/^\s*width:\s*100%\s*;/m);
    expect(videoRule).not.toMatch(/^\s*height:\s*100%\s*;/m);
  });

  it("keeps fullscreen loading placeholder out of the flex layout flow", () => {
    // The fullscreen loading label should overlay the stage while auth bytes
    // decode, otherwise the placeholder can consume flex space and shift media.
    const css = readFileSync(resolve(__dirname, "../styles.css"), "utf8");
    const loadingRuleMatch = css.match(/\.viewer-image-container > \.media-placeholder\s*\{[\s\S]*?\}/);
    expect(loadingRuleMatch).not.toBeNull();

    const loadingRule = loadingRuleMatch![0];
    expect(loadingRule).toContain("position: absolute");
    expect(loadingRule).toContain("width: auto");
    expect(loadingRule).toContain("height: auto");
  });

  it("removes stage and media framing only in browser fullscreen mode", () => {
    // Locks fullscreen-only spacing overrides so standard viewer mode keeps its
    // framed presentation while true fullscreen can render edge-to-edge media.
    const css = readFileSync(resolve(__dirname, "../styles.css"), "utf8");
    const fullscreenStageRule = css.match(/\.viewer:fullscreen \.viewer-stage\s*\{[\s\S]*?\}/);
    const fullscreenContainerRule = css.match(/\.viewer:fullscreen \.viewer-image-container\s*\{[\s\S]*?\}/);
    const fullscreenInfoOpenRule = css.match(/\.viewer:fullscreen\.info-open \.viewer-image-container\s*\{[\s\S]*?\}/);
    const fullscreenMediaRule = css.match(
      /\.viewer:fullscreen \.viewer-image,\s*\n\.viewer:fullscreen \.viewer-video,\s*\n\.viewer:fullscreen \.viewer-heic-canvas\s*\{[\s\S]*?\}/,
    );

    expect(fullscreenStageRule).not.toBeNull();
    expect(fullscreenContainerRule).not.toBeNull();
    expect(fullscreenInfoOpenRule).not.toBeNull();
    expect(fullscreenMediaRule).not.toBeNull();

    expect(fullscreenStageRule![0]).toContain("padding: 0");
    expect(fullscreenContainerRule![0]).toContain("inset: 0");
    expect(fullscreenInfoOpenRule![0]).toContain("right: 0");
    expect(fullscreenMediaRule![0]).toContain("border-radius: 0");
    expect(fullscreenMediaRule![0]).toContain("box-shadow: none");
  });

  it("fits portrait videos with the same explicit viewport sizing as images", async () => {
    const clientWidth = vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(559);
    const clientHeight = vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(900);

    try {
      const { container } = render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[
            {
              ...items[0],
              mediaType: "video",
              width: 2160,
              height: 3840,
              viewerUrl: "/api/decryptd/objects/video-1",
              isHeic: false,
              heicOriginalUrl: null,
            },
          ]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );

      const video = container.querySelector("video");
      await waitFor(() => {
        expect(video).toHaveStyle({ width: "506.25px", height: "900px" });
      });
    } finally {
      clientWidth.mockRestore();
      clientHeight.mockRestore();
    }
  });

  it("falls back to loaded video metadata when manifest dimensions are missing", async () => {
    const clientWidth = vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(559);
    const clientHeight = vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(900);

    try {
      const { container } = render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[
            {
              ...items[0],
              mediaType: "video",
              width: 0,
              height: 0,
              viewerUrl: "/api/decryptd/objects/video-1",
              isHeic: false,
              heicOriginalUrl: null,
            },
          ]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );

      const video = container.querySelector("video");
      expect(video).not.toBeNull();
      Object.defineProperty(video, "videoWidth", { configurable: true, value: 2160 });
      Object.defineProperty(video, "videoHeight", { configurable: true, value: 3840 });
      fireEvent.loadedMetadata(video as HTMLVideoElement);

      await waitFor(() => {
        expect(video).toHaveStyle({ width: "506.25px", height: "900px" });
      });
    } finally {
      clientWidth.mockRestore();
      clientHeight.mockRestore();
    }
  });

  it("prefers loaded video metadata over stale landscape manifest dimensions", async () => {
    const clientWidth = vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(559);
    const clientHeight = vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(900);

    try {
      const { container } = render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[
            {
              ...items[0],
              mediaType: "video",
              width: 3840,
              height: 2160,
              viewerUrl: "/api/decryptd/objects/video-1",
              isHeic: false,
              heicOriginalUrl: null,
            },
          ]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={null}
        />,
      );

      const video = container.querySelector("video");
      expect(video).not.toBeNull();
      Object.defineProperty(video, "videoWidth", { configurable: true, value: 2160 });
      Object.defineProperty(video, "videoHeight", { configurable: true, value: 3840 });
      fireEvent.loadedMetadata(video as HTMLVideoElement);

      await waitFor(() => {
        expect(video).toHaveStyle({ width: "506.25px", height: "900px" });
      });
    } finally {
      clientWidth.mockRestore();
      clientHeight.mockRestore();
    }
  });

  it("attempts client-side HEIC decode before rendering full stage", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(decodeHeicToCanvasBitmap).mockResolvedValue({
      width: 2,
      height: 2,
      pixels: new Uint8ClampedArray(16),
    });

    render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            isHeic: true,
            heicOriginalUrl: "/api/lfs/objects/heic-hash",
            viewerUrl: "/api/lfs/objects/heic-hash",
            intermediateViewerUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/lfs/objects/heic-hash", {
        headers: { authorization: "test" },
        signal: expect.any(AbortSignal),
      });
      expect(decodeHeicToCanvasBitmap).toHaveBeenCalled();
      const decodeArgs = vi.mocked(decodeHeicToCanvasBitmap).mock.calls.at(0);
      expect(decodeArgs?.[2]).toBeInstanceOf(AbortSignal);
    });
  });

  it("waits briefly before starting HEIC full decode", async () => {
    vi.useFakeTimers();
    try {
      const fetchMock = vi.fn().mockResolvedValue({
        ok: true,
        arrayBuffer: async () => new ArrayBuffer(8),
      });
      vi.stubGlobal("fetch", fetchMock);
      vi.mocked(decodeHeicToCanvasBitmap).mockResolvedValue({
        width: 2,
        height: 2,
        pixels: new Uint8ClampedArray(16),
      });

      render(
        <FullscreenViewer
          itemCount={1}
          loadedOffset={0}
          loadedItems={[
            {
              ...items[0],
              isHeic: true,
              heicOriginalUrl: "/api/lfs/objects/heic-hash",
              viewerUrl: "/api/lfs/objects/heic-hash",
              intermediateViewerUrl: null,
            },
          ]}
          index={0}
          onClose={vi.fn()}
          onChange={vi.fn()}
          mtlsHeaders={{ authorization: "test" }}
        />,
      );

      expect(vi.mocked(decodeHeicToCanvasBitmap)).not.toHaveBeenCalled();
      await act(async () => {
        vi.advanceTimersByTime(100);
        await Promise.resolve();
      });
      expect(vi.mocked(decodeHeicToCanvasBitmap)).not.toHaveBeenCalled();
      await act(async () => {
        vi.advanceTimersByTime(30);
        await Promise.resolve();
      });
      expect(vi.mocked(decodeHeicToCanvasBitmap)).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps raster fallback visible after HEIC decode completes", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(decodeHeicToCanvasBitmap).mockResolvedValue({
      width: 2,
      height: 2,
      pixels: new Uint8ClampedArray(16),
    });

    const { container } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            isHeic: true,
            heicOriginalUrl: "/api/lfs/objects/heic-hash",
            viewerUrl: "/api/lfs/objects/heic-hash",
            intermediateViewerUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      expect(container.querySelector("canvas")).not.toBeNull();
    });

    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    expect(img).toHaveAttribute("src", "/thumb-1.jpg");
  });

  it("hides the raster fallback once the HEIC canvas is painted so the shadow does not double", async () => {
    // The decoded HEIC canvas fully covers the thumbnail at identical size, so
    // leaving both visible stacks two identical drop shadows. The fallback img
    // must stay mounted (for decode failures) but be hidden once the canvas
    // paints, keeping the low->high transition shadow-stable and seamless.
    vi.stubGlobal(
      "ImageData",
      class {
        data: Uint8ClampedArray;
        width: number;
        height: number;
        constructor(data: Uint8ClampedArray, width: number, height: number) {
          this.data = data;
          this.width = width;
          this.height = height;
        }
      },
    );
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      putImageData: vi.fn(),
    } as unknown as CanvasRenderingContext2D);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(decodeHeicToCanvasBitmap).mockResolvedValue({
      width: 2,
      height: 2,
      pixels: new Uint8ClampedArray(16),
    });

    const { container } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            isHeic: true,
            heicOriginalUrl: "/api/lfs/objects/heic-hash",
            viewerUrl: "/api/lfs/objects/heic-hash",
            intermediateViewerUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      expect(container.querySelector("canvas.viewer-heic-ready")).not.toBeNull();
    });

    const img = container.querySelector("img.viewer-image");
    expect(img).not.toBeNull();
    expect(img).toHaveClass("viewer-image-covered");
  });

  it("keeps thumbnail visible when client HEIC decode fails", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(decodeHeicToCanvasBitmap).mockRejectedValue(new Error("decode failed"));

    render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            isHeic: true,
            heicOriginalUrl: "/api/lfs/objects/heic-hash",
            viewerUrl: "/api/lfs/objects/heic-hash",
            intermediateViewerUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      const image = screen.getByRole("img", { name: "2026-01-02T00:00:00Z" });
      expect(image).toHaveAttribute("src", "/thumb-1.jpg");
    });
    expect(vi.mocked(fetchAndCacheAuthenticatedMedia)).not.toHaveBeenCalledWith(
      expect.objectContaining({ src: "/api/lfs/objects/heic-hash" }),
    );
  });

  it("ignores HEIC decode aborts without logging decode-failed warnings", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    const abortError = new Error("HEIC decode aborted");
    abortError.name = "AbortError";
    vi.mocked(decodeHeicToCanvasBitmap).mockRejectedValue(abortError);
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            isHeic: true,
            heicOriginalUrl: "/api/lfs/objects/heic-hash",
            viewerUrl: "/api/lfs/objects/heic-hash",
            intermediateViewerUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={{ authorization: "test" }}
      />,
    );

    await waitFor(() => {
      expect(decodeHeicToCanvasBitmap).toHaveBeenCalled();
    });
    expect(
      warnSpy.mock.calls.some((call) => String(call[0]).includes("[replycant-heic] client decode failed")),
    ).toBe(false);
  });

  it("cancels pending HEIC decode when selection changes before debounce elapses", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(decodeHeicToCanvasBitmap).mockResolvedValue({
      width: 2,
      height: 2,
      pixels: new Uint8ClampedArray(16),
    });

    const rapidItems = [
      {
        ...items[0],
        key: "rapid-heic",
        isHeic: true,
        heicOriginalUrl: "/api/lfs/objects/rapid-heic",
        viewerUrl: "/api/lfs/objects/rapid-heic",
        intermediateViewerUrl: null,
      },
      {
        ...items[1],
        key: "rapid-jpeg",
        isHeic: false,
        heicOriginalUrl: null,
        viewerUrl: "/full-2.jpg",
      },
    ];
    const ViewerHarness = () => {
      const [index, setIndex] = useState(0);
      return (
        <>
          <button type="button" onClick={() => setIndex(1)}>
            Switch item
          </button>
          <FullscreenViewer
            itemCount={rapidItems.length}
            loadedOffset={0}
            loadedItems={rapidItems}
            index={index}
            onClose={vi.fn()}
            onChange={(nextIndex) => setIndex(nextIndex)}
            mtlsHeaders={{ authorization: "test" }}
          />
        </>
      );
    };

    render(<ViewerHarness />);
    fireEvent.click(screen.getByRole("button", { name: "Switch item" }));
    await act(async () => {
      vi.advanceTimersByTime(300);
    });
    expect(vi.mocked(decodeHeicToCanvasBitmap)).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it("renders only the streamlined toolbar controls", () => {
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    expect(screen.getByLabelText("Download")).toBeInTheDocument();
    expect(screen.getByLabelText("Enter fullscreen")).toBeInTheDocument();
    expect(screen.queryByLabelText("Favorite")).toBeNull();
    expect(screen.queryByLabelText("Share")).toBeNull();
    expect(screen.queryByTitle("More")).toBeNull();
    expect(screen.queryByText("142 / 27,973")).toBeNull();
  });

  it("toggles the info panel from the info button", () => {
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    expect(screen.queryByRole("heading", { name: "Details" })).toBeNull();
    fireEvent.click(screen.getByLabelText("Info"));
    expect(screen.getByRole("heading", { name: "Details" })).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText("Info"));
    expect(screen.queryByRole("heading", { name: "Details" })).toBeNull();
  });

  it("toggles the info panel with the i keyboard shortcut", () => {
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    expect(screen.queryByRole("heading", { name: "Details" })).toBeNull();
    fireEvent.keyDown(window, { key: "i" });
    expect(screen.getByRole("heading", { name: "Details" })).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "i" });
    expect(screen.queryByRole("heading", { name: "Details" })).toBeNull();
  });

  it("toggles video playback with the spacebar shortcut", () => {
    const { container } = render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            mediaType: "video",
            mimeType: "video/mp4",
            viewerUrl: "/api/decryptd/objects/video-1",
            isHeic: false,
            heicOriginalUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    const video = container.querySelector("video") as HTMLVideoElement;
    expect(video).not.toBeNull();
    const playSpy = vi.fn().mockResolvedValue(undefined);
    const pauseSpy = vi.fn();
    let paused = true;
    Object.defineProperty(video, "play", { configurable: true, value: playSpy });
    Object.defineProperty(video, "pause", { configurable: true, value: pauseSpy });
    Object.defineProperty(video, "paused", {
      configurable: true,
      get: () => paused,
    });

    fireEvent.keyDown(window, { key: " " });
    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(pauseSpy).not.toHaveBeenCalled();

    paused = false;
    fireEvent.keyDown(window, { key: " " });
    expect(pauseSpy).toHaveBeenCalledTimes(1);
  });

  it("shows image metadata in the info panel", () => {
    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    fireEvent.click(screen.getByLabelText("Info"));

    expect(screen.getByText("IMG_0001.jpg")).toBeInTheDocument();
    expect(screen.getByText("100 x 100")).toBeInTheDocument();
    expect(screen.getByText("image/jpeg")).toBeInTheDocument();
    expect(screen.getByText("5.0 MB")).toBeInTheDocument();
  });

  it("shows video duration and playback mode in the info panel", () => {
    render(
      <FullscreenViewer
        itemCount={1}
        loadedOffset={0}
        loadedItems={[
          {
            ...items[0],
            mediaType: "video",
            mimeType: "video/mp4",
            duration: 61,
            width: 1920,
            height: 1080,
            viewerUrl: "/api/decryptd/objects/video-1",
            isHeic: false,
            heicOriginalUrl: null,
          },
        ]}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    fireEvent.click(screen.getByLabelText("Info"));

    expect(screen.getByText("1:01")).toBeInTheDocument();
    expect(screen.getByText("Direct Play")).toBeInTheDocument();
    expect(screen.getByText("1920 x 1080")).toBeInTheDocument();
  });

  it("requests browser fullscreen from the toolbar button", () => {
    const requestFullscreen = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(HTMLElement.prototype, "requestFullscreen", {
      configurable: true,
      value: requestFullscreen,
    });

    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    fireEvent.click(screen.getByLabelText("Enter fullscreen"));
    expect(requestFullscreen).toHaveBeenCalled();
  });

  it("requests browser fullscreen when pressing f", () => {
    const requestFullscreen = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(HTMLElement.prototype, "requestFullscreen", {
      configurable: true,
      value: requestFullscreen,
    });

    render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    fireEvent.keyDown(window, { key: "f" });
    expect(requestFullscreen).toHaveBeenCalled();
  });

  it("hides chrome after inactivity and reveals on movement", async () => {
    vi.useFakeTimers();
    const { container } = render(
      <FullscreenViewer
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        index={0}
        onClose={vi.fn()}
        onChange={vi.fn()}
        mtlsHeaders={null}
      />,
    );

    const viewer = container.querySelector(".viewer");
    expect(viewer).not.toHaveClass("idle");
    await act(async () => {
      vi.advanceTimersByTime(2600);
    });
    expect(viewer).toHaveClass("idle");
    fireEvent.mouseMove(viewer as Element);
    expect(viewer).not.toHaveClass("idle");
    vi.useRealTimers();
  });
});
