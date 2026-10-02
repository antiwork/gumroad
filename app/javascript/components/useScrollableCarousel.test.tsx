// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useScrollableCarousel } from "$app/components/useScrollableCarousel";

const CARD_WIDTH = 100;
const CARD_COUNT = 8;
const VIEWPORT_WIDTH = 300;

const Carousel = ({ onActiveChange }: { onActiveChange: (index: number) => void }) => {
  const { itemsRef, handleScroll } = useScrollableCarousel(0, onActiveChange);
  return (
    <div data-testid="track" ref={itemsRef} onScroll={handleScroll}>
      {Array.from({ length: CARD_COUNT }, (_, i) => (
        <div key={i} />
      ))}
    </div>
  );
};

// happy-dom does no layout, so describe a track of 8 cards where 3 fit in view.
const layOut = (track: HTMLElement) => {
  Object.defineProperty(track, "clientWidth", { configurable: true, value: VIEWPORT_WIDTH });
  Object.defineProperty(track, "scrollWidth", { configurable: true, value: CARD_COUNT * CARD_WIDTH });
  [...track.children].forEach((child, i) => {
    Object.defineProperty(child, "offsetLeft", { configurable: true, value: i * CARD_WIDTH });
    Object.defineProperty(child, "offsetWidth", { configurable: true, value: CARD_WIDTH });
  });
};

describe("useScrollableCarousel", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    Element.prototype.scroll = vi.fn();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  const scrollTo = (track: HTMLElement, scrollLeft: number) => {
    track.scrollLeft = scrollLeft;
    fireEvent.scroll(track);
    act(() => {
      vi.advanceTimersByTime(150);
    });
  };

  it("reports the card at the left edge while scrolled mid-track", () => {
    const onActiveChange = vi.fn();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, 2 * CARD_WIDTH);

    expect(onActiveChange).toHaveBeenLastCalledWith(2);
  });

  it("reports the last card when the track is scrolled to its end", () => {
    const onActiveChange = vi.fn();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, CARD_COUNT * CARD_WIDTH - VIEWPORT_WIDTH);

    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 1);
  });
});
