// Bounded async channel modeled after Go buffered channels, providing backpressure
// between producer and consumer stages in the streaming rehydration pipeline.
export class BoundedChannel<T> {
  private buffer: T[] = [];
  private closed = false;
  private resolveItemAvailable: (() => void) | null = null;
  private resolveSpaceAvailable: (() => void) | null = null;

  constructor(private readonly capacity: number) {
    if (capacity < 1) throw new Error("BoundedChannel capacity must be >= 1");
  }

  // Sends an item into the channel. Awaits if the buffer is full (backpressure).
  async send(item: T): Promise<void> {
    if (this.closed) throw new Error("Cannot send on a closed channel");
    while (this.buffer.length >= this.capacity) {
      await new Promise<void>((resolve) => {
        this.resolveSpaceAvailable = resolve;
      });
    }
    this.buffer.push(item);
    this.resolveItemAvailable?.();
    this.resolveItemAvailable = null;
  }

  close(): void {
    this.closed = true;
    this.resolveItemAvailable?.();
    this.resolveItemAvailable = null;
  }

  // Yields items as they arrive. Completes when the channel is closed and drained.
  async *receive(): AsyncGenerator<T, void, undefined> {
    while (true) {
      while (this.buffer.length > 0) {
        const item = this.buffer.shift()!;
        this.resolveSpaceAvailable?.();
        this.resolveSpaceAvailable = null;
        yield item;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => {
        this.resolveItemAvailable = resolve;
      });
    }
  }
}
