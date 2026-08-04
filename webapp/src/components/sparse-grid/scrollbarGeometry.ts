// Captures the geometry the overlay scrollbar needs for consistent drag math.
export interface ScrollbarGeometry {
  visible: boolean;
  thumbHeight: number;
  thumbTop: number;
  maxThumbTop: number;
  maxScrollTop: number;
}

interface ScrollbarGeometryInput {
  scrollTop: number;
  totalHeight: number;
  viewportHeight: number;
  trackHeight: number;
  minThumbHeight?: number;
}

// Computes thumb dimensions/position so the overlay scrollbar mirrors native scrolling.
export const scrollbarGeometry = ({
  scrollTop,
  totalHeight,
  viewportHeight,
  trackHeight,
  minThumbHeight = 48,
}: ScrollbarGeometryInput): ScrollbarGeometry => {
  if (trackHeight <= 0 || totalHeight <= viewportHeight || viewportHeight <= 0) {
    return {
      visible: false,
      thumbHeight: 0,
      thumbTop: 0,
      maxThumbTop: 0,
      maxScrollTop: 0,
    };
  }

  const maxScrollTop = Math.max(0, totalHeight - viewportHeight);
  const thumbHeight = Math.max(minThumbHeight, (viewportHeight / totalHeight) * trackHeight);
  const maxThumbTop = Math.max(0, trackHeight - thumbHeight);
  const normalized = maxScrollTop === 0 ? 0 : Math.min(1, Math.max(0, scrollTop / maxScrollTop));
  const thumbTop = normalized * maxThumbTop;

  return {
    visible: true,
    thumbHeight,
    thumbTop,
    maxThumbTop,
    maxScrollTop,
  };
};
