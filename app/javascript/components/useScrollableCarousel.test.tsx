// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useScrollableCarousel } from "$app/components/useScrollableCarousel";

const CARD_WIDTH = 100;
const CARD_COUNT = 8;
const VIEWPORT_WIDTH = 300;

const Carousel = ({ onActiveChange }: { onActiveChange: (index: number) => void }) => {
  const [active, setActive] = React.useState(0);
  const update = (index: number) => {
    setActive(index);
    onActiveChange(index);
  };
  const { itemsRef, handleScroll, getPreviousIndex } = useScrollableCarousel(active, update);
  return (
    <>
      <button data-testid="previous" onClick={() => update(getPreviousIndex(CARD_COUNT))} />
      <button data-testid="next" onClick={() => update((active + 1) % CARD_COUNT)} />
      <div data-testid="track" ref={itemsRef} onScroll={handleScroll}>
        {Array.from({ length: CARD_COUNT }, (_, i) => (
          <div key={i} />
        ))}
      </div>
    </>
  );
};

// happy-dom does no layout, so describe a track of 8 cards where 3 fit in view.
const layOut = (track: HTMLElement, scrollWidth = CARD_COUNT * CARD_WIDTH) => {
  Object.defineProperty(track, "clientWidth", { configurable: true, value: VIEWPORT_WIDTH });
  Object.defineProperty(track, "scrollWidth", { configurable: true, value: scrollWidth });
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
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, 2 * CARD_WIDTH);

    expect(onActiveChange).toHaveBeenLastCalledWith(2);
  });

  it("reports the last card when the track is scrolled to its end", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, CARD_COUNT * CARD_WIDTH - VIEWPORT_WIDTH);

    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 1);
  });

  it("steps back from the card at the left edge when the track is at its end", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, CARD_COUNT * CARD_WIDTH - VIEWPORT_WIDTH);
    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 1);

    fireEvent.click(getByTestId("previous"));

    // Card 5 is at the left edge, so the previous card is 4 rather than the unreachable card 6.
    expect(onActiveChange).toHaveBeenLastCalledWith(4);
  });

  it("keeps stepping one card per click while the smooth scroll is still in flight", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, CARD_COUNT * CARD_WIDTH - VIEWPORT_WIDTH);
    fireEvent.click(getByTestId("previous"));
    // The track has not moved yet, as during a smooth scroll.
    fireEvent.click(getByTestId("previous"));
    fireEvent.click(getByTestId("previous"));

    expect(onActiveChange.mock.calls.map(([index]) => index)).toEqual([CARD_COUNT - 1, 4, 3, 2]);
  });

  it("steps back from the counter when Previous follows Next while the track is still scrolling", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, 5 * CARD_WIDTH - 200);
    scrollTo(track, 300);
    expect(onActiveChange).toHaveBeenLastCalledWith(3);
    for (let i = 3; i < 5; i++) fireEvent.click(getByTestId("next"));
    expect(onActiveChange).toHaveBeenLastCalledWith(5);
    // The track is still at 300 while the smooth scroll toward card 5 runs.
    fireEvent.click(getByTestId("next"));
    fireEvent.click(getByTestId("previous"));

    expect(onActiveChange).toHaveBeenLastCalledWith(5);
  });

  it("undoes Next with Previous when Next lands on a card the track cannot reach", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, CARD_COUNT * CARD_WIDTH - VIEWPORT_WIDTH);
    // The track stays at its end while the arrows are clicked in quick succession.
    fireEvent.click(getByTestId("previous"));
    fireEvent.click(getByTestId("next"));
    fireEvent.click(getByTestId("next"));
    fireEvent.click(getByTestId("previous"));

    expect(onActiveChange.mock.calls.map(([index]) => index)).toEqual([CARD_COUNT - 1, 4, 5, 6, 5]);
  });

  it("steps back from the counter when every card fits in view", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track, VIEWPORT_WIDTH);

    fireEvent.click(getByTestId("next"));
    fireEvent.click(getByTestId("next"));
    fireEvent.click(getByTestId("previous"));

    expect(onActiveChange.mock.calls.map(([index]) => index)).toEqual([1, 2, 1]);
  });

  it("steps back from the counter when the track overflows by less than a card at its end", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track, VIEWPORT_WIDTH + 10);

    scrollTo(track, 10);
    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 1);
    fireEvent.click(getByTestId("previous"));

    // The left-edge card is the first one, so wrapping from it would leave the counter unchanged.
    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 2);
  });

  it("wraps to the last card when going back from the start", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track);

    scrollTo(track, 0);
    fireEvent.click(getByTestId("previous"));

    expect(onActiveChange).toHaveBeenLastCalledWith(CARD_COUNT - 1);
  });

  it("does not treat a track that overflows by less than the tolerance as scrolled to its end", () => {
    const onActiveChange = vi.fn<(index: number) => void>();
    const { getByTestId } = render(<Carousel onActiveChange={onActiveChange} />);
    const track = getByTestId("track");
    layOut(track, VIEWPORT_WIDTH + 1);

    scrollTo(track, 0);

    expect(onActiveChange).toHaveBeenLastCalledWith(0);
  });
});
