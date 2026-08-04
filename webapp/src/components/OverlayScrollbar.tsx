import { MouseEvent, RefObject, useCallback, useEffect, useRef, useState } from "react";
import { scrollbarGeometry } from "./sparse-grid/scrollbarGeometry";

interface OverlayScrollbarProps {
  scrollRef: RefObject<HTMLElement | null>;
  getScrollLabel?: () => string | null;
  minThumbHeight?: number;
}

// Mirrors native scrolling with a draggable overlay thumb for dense media navigation.
export const OverlayScrollbar = ({ scrollRef, getScrollLabel, minThumbHeight = 48 }: OverlayScrollbarProps) => {
  const trackRef = useRef<HTMLDivElement | null>(null);
  const dragOffsetRef = useRef(0);
  const [scrollTick, setScrollTick] = useState(0);
  const [dragging, setDragging] = useState(false);

  // Re-measures thumb geometry whenever the scroll host moves or resizes.
  useEffect(() => {
    const scrollElement = scrollRef.current;
    if (!scrollElement) {
      return;
    }
    const bumpScrollTick = () => setScrollTick((value) => value + 1);
    scrollElement.addEventListener("scroll", bumpScrollTick);
    const resizeObserver = typeof ResizeObserver !== "undefined"
      ? new ResizeObserver(() => bumpScrollTick())
      : null;
    resizeObserver?.observe(scrollElement);
    if (trackRef.current) {
      resizeObserver?.observe(trackRef.current);
    }
    bumpScrollTick();
    return () => {
      scrollElement.removeEventListener("scroll", bumpScrollTick);
      resizeObserver?.disconnect();
    };
  }, [scrollRef]);

  const scrollTop = scrollRef.current?.scrollTop ?? 0;
  const viewportHeight = scrollRef.current?.clientHeight ?? 0;
  const totalHeight = scrollRef.current?.scrollHeight ?? 0;
  const trackHeight = trackRef.current?.clientHeight || Math.max(0, viewportHeight - 16);
  const geometry = scrollbarGeometry({
    scrollTop,
    totalHeight,
    viewportHeight,
    trackHeight,
    minThumbHeight,
  });
  const label = getScrollLabel?.() ?? null;

  // Maps drag-space coordinates into scrollTop so clicks and drags stay aligned.
  const scrollFromTrackTop = useCallback((nextThumbTop: number) => {
    if (!geometry.visible) return;
    const scrollElement = scrollRef.current;
    if (!scrollElement) return;
    const bounded = Math.min(geometry.maxThumbTop, Math.max(0, nextThumbTop));
    const ratio = geometry.maxThumbTop === 0 ? 0 : bounded / geometry.maxThumbTop;
    scrollElement.scrollTop = ratio * geometry.maxScrollTop;
    setScrollTick((value) => value + 1);
  }, [geometry.maxScrollTop, geometry.maxThumbTop, geometry.visible, scrollRef]);

  // Starts thumb dragging for fast scrollbar scrubbing in long lists.
  const handleThumbMouseDown = useCallback((event: MouseEvent<HTMLDivElement>) => {
    event.preventDefault();
    if (!geometry.visible) return;
    const trackRect = trackRef.current?.getBoundingClientRect();
    if (!trackRect) return;
    dragOffsetRef.current = event.clientY - trackRect.top - geometry.thumbTop;
    setDragging(true);
  }, [geometry.thumbTop, geometry.visible]);

  // Jumps scroll position when clicking outside the thumb on the scrollbar track.
  const handleTrackMouseDown = useCallback((event: MouseEvent<HTMLDivElement>) => {
    if ((event.target as HTMLElement).classList.contains("timeline-scrollbar-thumb")) return;
    if (!geometry.visible) return;
    const trackRect = trackRef.current?.getBoundingClientRect();
    if (!trackRect) return;
    scrollFromTrackTop(event.clientY - trackRect.top - geometry.thumbHeight / 2);
    setDragging(true);
    dragOffsetRef.current = geometry.thumbHeight / 2;
  }, [geometry.thumbHeight, geometry.visible, scrollFromTrackTop]);

  // Keeps drag interactions alive even when cursor leaves the scrollbar track.
  useEffect(() => {
    if (!dragging) return;
    const handleMouseMove = (event: globalThis.MouseEvent) => {
      const trackRect = trackRef.current?.getBoundingClientRect();
      if (!trackRect) return;
      scrollFromTrackTop(event.clientY - trackRect.top - dragOffsetRef.current);
    };
    const handleMouseUp = () => {
      setDragging(false);
    };
    window.addEventListener("mousemove", handleMouseMove);
    window.addEventListener("mouseup", handleMouseUp);
    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      window.removeEventListener("mouseup", handleMouseUp);
    };
  }, [dragging, scrollFromTrackTop]);

  void scrollTick;

  if (!geometry.visible) {
    return null;
  }

  return (
    <div
      ref={trackRef}
      className={`timeline-scrollbar${dragging ? " dragging" : ""}`}
      onMouseDown={handleTrackMouseDown}
      aria-hidden="true"
    >
      <div
        className="timeline-scrollbar-thumb"
        style={{
          height: `${geometry.thumbHeight}px`,
          transform: `translateY(${geometry.thumbTop}px)`,
        }}
        onMouseDown={handleThumbMouseDown}
      />
      {label ? (
        <div
          className="timeline-scrollbar-label"
          style={{
            transform: `translateY(${geometry.thumbTop + geometry.thumbHeight / 2}px)`,
          }}
        >
          {label}
        </div>
      ) : null}
    </div>
  );
};
