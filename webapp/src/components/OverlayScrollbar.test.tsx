import { createRef } from "react";
import { fireEvent, render, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { OverlayScrollbar } from "./OverlayScrollbar";

describe("OverlayScrollbar", () => {
  it("renders a thumb when scrolling is possible", async () => {
    const scrollElement = document.createElement("div");
    const scrollRef = createRef<HTMLElement>();
    scrollRef.current = scrollElement;
    Object.defineProperty(scrollElement, "clientHeight", { configurable: true, value: 200 });
    Object.defineProperty(scrollElement, "scrollHeight", { configurable: true, value: 1000 });
    scrollElement.scrollTop = 0;

    const { container } = render(<OverlayScrollbar scrollRef={scrollRef} />);

    await waitFor(() => {
      expect(container.querySelector(".timeline-scrollbar-thumb")).not.toBeNull();
    });
  });

  it("updates container scroll position when dragging the thumb", async () => {
    const scrollElement = document.createElement("div");
    const scrollRef = createRef<HTMLElement>();
    scrollRef.current = scrollElement;
    Object.defineProperty(scrollElement, "clientHeight", { configurable: true, value: 250 });
    Object.defineProperty(scrollElement, "scrollHeight", { configurable: true, value: 1000 });
    scrollElement.scrollTop = 0;

    const { container } = render(<OverlayScrollbar scrollRef={scrollRef} />);
    const track = container.querySelector(".timeline-scrollbar") as HTMLDivElement;
    const thumb = container.querySelector(".timeline-scrollbar-thumb") as HTMLDivElement;
    Object.defineProperty(track, "clientHeight", { configurable: true, value: 200 });
    track.getBoundingClientRect = () =>
      ({ x: 0, y: 0, top: 0, left: 0, right: 10, bottom: 200, width: 10, height: 200, toJSON: () => ({}) });

    fireEvent.mouseDown(thumb, { clientY: 10 });
    fireEvent.mouseMove(window, { clientY: 140 });
    fireEvent.mouseUp(window);

    await waitFor(() => {
      expect(scrollElement.scrollTop).toBeGreaterThan(0);
    });
  });

  it("hides the thumb when content does not overflow", async () => {
    const scrollElement = document.createElement("div");
    const scrollRef = createRef<HTMLElement>();
    scrollRef.current = scrollElement;
    Object.defineProperty(scrollElement, "clientHeight", { configurable: true, value: 400 });
    Object.defineProperty(scrollElement, "scrollHeight", { configurable: true, value: 400 });
    scrollElement.scrollTop = 0;

    const { container } = render(<OverlayScrollbar scrollRef={scrollRef} />);

    await waitFor(() => {
      expect(container.querySelector(".timeline-scrollbar-thumb")).toBeNull();
    });
  });
});
