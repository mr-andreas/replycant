import { ReactNode } from "react";

// Describes a sparse loaded segment so large datasets stay virtualized.
export interface SparseGridWindow<TItem> {
  loadedOffset: number;
  loadedItems: TItem[];
}

// Describes the minimal data source contract needed by the generic sparse grid.
export interface SparseGridDataSource<TItem> {
  itemCount: number;
  window: SparseGridWindow<TItem>;
  onLoadOlder: () => void;
  onLoadNewer: () => void;
  onSeekToIndex: (index: number) => void;
}

// Carries a stable viewport marker so wrappers can persist location externally.
export interface SparseGridAnchor {
  itemKey: string;
  offsetPx: number;
}

// Provides per-item metadata so wrappers can customize tile rendering policy.
export interface SparseGridRenderContext<TItem> {
  item: TItem;
  index: number;
  inViewport: boolean;
  tileSizePx: number;
}

// Exposes imperative jump controls for side rails and deep links.
export interface SparseGridHandle {
  scrollToIndex: (index: number) => void;
  scrollToAnchor: (anchor: SparseGridAnchor) => void;
}

// Defines public props shape for consumers that compose the generic grid.
export interface SparseGridProps<TItem> {
  dataSource: SparseGridDataSource<TItem>;
  getItemKey: (item: TItem) => string;
  renderItem: (context: SparseGridRenderContext<TItem>) => ReactNode;
  renderPlaceholder?: (index: number) => ReactNode;
  onItemClick?: (item: TItem, index: number) => void;
  initialAnchor?: SparseGridAnchor | null;
  onViewportAnchorChange?: (anchor: SparseGridAnchor & { index: number }) => void;
  onVisibleRangeChange?: (range: { firstIndex: number; lastIndex: number }) => void;
  showScrollbar?: boolean;
  getScrollLabel?: (topIndex: number) => string;
  className?: string;
}
