import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { type ForwardedRef, forwardRef, useImperativeHandle } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { TimelineItem } from "../../lib/timeline";
import { TimelineView } from "./TimelineView";

const timelineScrollToIndexSpy = vi.fn();

vi.mock("../../components/Timeline", () => ({
  Timeline: forwardRef((props: Record<string, unknown>, ref: ForwardedRef<{ scrollToIndex: (index: number) => void }>) => {
    useImperativeHandle(ref, () => ({ scrollToIndex: timelineScrollToIndexSpy }), []);
    const onOpen = props.onOpen as (index: number) => void;
    return (
      <button type="button" onClick={() => onOpen(1)}>
        Open viewer
      </button>
    );
  }),
}));

const testEncryption = {
  encryptedOid: "video-1",
  wrappedDek: "wrapped",
  kekEpoch: 1,
  dekBase64: "a+b/c=",
};

const buildItems = (): TimelineItem[] => [
  {
    key: "item-0",
    dayKey: "2026-01-01",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-01T12:00:00Z",
    mediaType: "photo",
    sha256: "hash-0",
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-0.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/full-0.jpg",
    downloadUrl: "/api/lfs/objects/hash-0",
    originalFileName: "item-0.jpg",
    thumbnailEncryption: testEncryption,
  },
  {
    key: "item-1",
    dayKey: "2026-01-02",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-02T12:00:00Z",
    mediaType: "video",
    sha256: "hash-1",
    filesize: 1000,
    width: 1920,
    height: 1080,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "video/mp4",
    thumbnailUrl: "/thumb-video.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/api/decryptd/objects/video-1",
    downloadUrl: "/api/lfs/objects/hash-1",
    originalFileName: "item-1.mp4",
    encryption: testEncryption,
    thumbnailEncryption: { ...testEncryption, encryptedOid: "thumb-video" },
  },
  {
    key: "item-2",
    dayKey: "2026-01-03",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-03T12:00:00Z",
    mediaType: "photo",
    sha256: "hash-2",
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-2.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/full-2.jpg",
    downloadUrl: "/api/lfs/objects/hash-2",
    originalFileName: "item-2.jpg",
    thumbnailEncryption: { ...testEncryption, encryptedOid: "thumb-2" },
  },
];

const makeRuntime = (
  loadedItems: TimelineItem[],
  overrides?: Partial<{
    loadedOffset: number;
  }>,
) => ({
  snapshot: { syncing: false },
  timelineItemCount: 3,
  timelineMonthIndex: [],
  timelineWindow: {
    loadedOffset: overrides?.loadedOffset ?? 0,
    loadedItems,
  },
  timelineDataSource: null,
  rewindCommits: [],
  rewindActionBusy: null,
  initializeEngine: vi.fn(),
  handleSyncNow: vi.fn(),
  handleResetToRemote: vi.fn(),
  handleJumpToCommit: vi.fn(),
  wipeReplycantState: vi.fn(),
  loadOlderPage: vi.fn(),
  loadNewerPage: vi.fn(),
  seekToIndex: vi.fn(),
});

describe("TimelineView video sync behavior", () => {
  beforeEach(() => {
    timelineScrollToIndexSpy.mockReset();
    window.history.replaceState(null, "", "#");
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    );
  });

  it("does not reassign video src when only loadedOffset shifts with same loaded items", async () => {
    const allItems = buildItems();
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
        <TimelineView
          runtime={makeRuntime(allItems) as never}
          mtlsHeaders={null}
          activeView="timeline"
          onSelectView={vi.fn()}
          commitPaneOpen={false}
          onToggleCommitPane={vi.fn()}
          commitPane={null}
        />,
      );

      fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
      await waitFor(() => {
        expect(srcSetSpy).toHaveBeenCalledWith("/api/decryptd/objects/video-1?dek=a%2Bb%2Fc%3D");
      });
      srcSetSpy.mockClear();

      rerender(
        <TimelineView
          runtime={makeRuntime(allItems, { loadedOffset: 1 }) as never}
          mtlsHeaders={null}
          activeView="timeline"
          onSelectView={vi.fn()}
          commitPaneOpen={false}
          onToggleCommitPane={vi.fn()}
          commitPane={null}
        />,
      );

      expect(srcSetSpy).not.toHaveBeenCalled();
    } finally {
      Object.defineProperty(HTMLMediaElement.prototype, "src", srcDescriptor);
    }
  });
});
