// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AssetPreview } from "$app/parsers/product";

import { Covers } from "$app/components/Product/Covers";

// The video cover boots JW Player from the cloud library on mount. Stub it so the
// component renders without network access, and so the setup options can be asserted.
const createJWPlayer = vi.hoisted(() => vi.fn((_containerId: string, _options: Record<string, unknown>) => {}));
vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer }));

// happy-dom reports every element as 0x0 and has no ResizeObserver, but a cover item
// only renders its child once it has measured a non-zero width. Give it both.
class ResizeObserverStub {
  callback: () => void;
  constructor(callback: () => void) {
    this.callback = callback;
  }
  observe() {
    this.callback();
  }
  disconnect() {}
}
vi.stubGlobal("ResizeObserver", ResizeObserverStub);
Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, value: 670 });
Object.defineProperty(HTMLElement.prototype, "clientHeight", { configurable: true, value: 376 });

afterEach(() => {
  cleanup();
  createJWPlayer.mockReset();
});

const cover = (overrides: Partial<AssetPreview> = {}): AssetPreview => ({
  type: "video",
  filetype: "mp4",
  id: "cover-1",
  url: "https://example.test/cover.mp4",
  original_url: "https://example.test/cover-original.mp4",
  thumbnail: null,
  width: 670,
  height: 376,
  native_width: 1920,
  native_height: 1080,
  ...overrides,
});

const portrait = (overrides: Partial<AssetPreview> = {}) =>
  cover({ width: 670, height: 1191, native_width: 1080, native_height: 1920, ...overrides });

const renderCovers = (covers: AssetPreview[], activeCoverId = covers[0]?.id ?? null) =>
  render(<Covers covers={covers} activeCoverId={activeCoverId} setActiveCoverId={() => {}} />);

const frame = (container: HTMLElement) => container.querySelector<HTMLElement>("figure > div");

describe("Covers", () => {
  it("shapes the frame to a landscape cover's own ratio", () => {
    const { container } = renderCovers([cover()]);

    expect(frame(container)?.style.aspectRatio).toBe("1920 / 1080");
  });

  it("shapes the frame to a portrait cover and caps its height so the buy box stays in view", () => {
    const { container } = renderCovers([portrait()]);

    expect(frame(container)?.style.aspectRatio).toBe("1080 / 1920");
    expect(frame(container)?.style.maxHeight).toBe("80svh");
  });

  // Previously the ratio came from covers[0] no matter which cover was on screen, so a
  // portrait cover behind a landscape one was fit into a 16:9 frame and cropped.
  it("follows the active cover rather than the first one", () => {
    const { container } = renderCovers([cover(), portrait({ id: "cover-2" })], "cover-2");

    expect(frame(container)?.style.aspectRatio).toBe("1080 / 1920");
  });

  // The frame must keep the column's full width whatever the ratio: the carousel picks
  // the active cover by comparing scroll offsets against panel widths, so a frame that
  // narrowed for portrait covers would bounce a two-cover carousel back to the first.
  it("keeps the frame full-width so the carousel's scroll maths still holds", () => {
    const { container } = renderCovers([portrait()]);

    expect(frame(container)?.style.width).toBe("100%");
  });

  it("leaves the frame unshaped when the active cover has no recorded dimensions", () => {
    const { container } = renderCovers([cover({ native_width: null, native_height: null })]);

    expect(frame(container)?.style.aspectRatio).toBe("");
    expect(frame(container)?.style.maxHeight).toBe("");
    expect(frame(container)?.style.width).toBe("");
  });

  it("keeps the thumbnail variant unshaped", () => {
    const { container } = render(
      <Covers covers={[portrait()]} activeCoverId="cover-1" setActiveCoverId={() => {}} isThumbnail />,
    );

    expect(frame(container)?.style.aspectRatio).toBe("");
  });

  it("tells the player the cover video's real ratio", async () => {
    renderCovers([portrait()]);

    await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
    expect(createJWPlayer.mock.calls[0]?.[1]).toMatchObject({ aspectratio: "1080:1920" });
  });

  it("sizes the video box by ratio so it shrinks to fit the capped frame", () => {
    const { container } = renderCovers([portrait()]);
    const box = container.querySelector<HTMLElement>("[role=tabpanel] > div");

    expect(box?.style.aspectRatio).toBe("1080 / 1920");
    expect(box?.style.height).toBe("100%");
    // The old percentage padding derives height from width alone, so a portrait video
    // ignored the frame's height cap and spilled out of the figure.
    expect(box?.style.paddingBottom).toBe("");
  });

  it("keeps the old percentage-padding box for a video with no recorded dimensions", () => {
    // CoverItem needs both dimension pairs before it renders a player at all, so this
    // also pins that an old dimension-less upload reaches neither the ratio nor the cap.
    renderCovers([cover({ native_width: null, native_height: null })]);

    expect(createJWPlayer).not.toHaveBeenCalled();
  });

  it("still renders the carousel arrows for a multi-cover product", () => {
    renderCovers([cover(), portrait({ id: "cover-2" })]);

    expect(screen.getByRole("button", { name: "Show next cover" })).toBeTruthy();
  });

  // Capping the frame's height affects every cover TYPE, not just video. An image or
  // embed sized from its width alone overflows a capped frame and gets cropped top and
  // bottom — which is the bug this PR fixes, reintroduced on a different cover type.
  it("keeps a portrait image cover inside the capped frame instead of cropping it", () => {
    const { container } = renderCovers([portrait({ type: "image", filetype: "png" })]);
    const image = container.querySelector<HTMLImageElement>("img");

    expect(image?.className).toContain("max-h-full");
    expect(image?.className).toContain("object-contain");
  });

  it("sizes a portrait embed cover by ratio so it shrinks to fit the capped frame", () => {
    const { container } = renderCovers([portrait({ type: "oembed", filetype: null })]);
    const box = container.querySelector<HTMLElement>("[role=tabpanel] > div");

    expect(box?.style.aspectRatio).toBe("1080 / 1920");
    expect(box?.style.height).toBe("100%");
    expect(box?.style.paddingBottom).toBe("");
  });

  it("keeps the old percentage-padding box for an embed with no recorded dimensions", () => {
    const { container } = renderCovers([
      cover({ type: "oembed", filetype: null, native_width: null, native_height: null }),
    ]);

    // No native dimensions means CoverItem renders nothing at all, so there is no box to
    // reshape — the same fallback the video path takes.
    expect(container.querySelector("[role=tabpanel] > div")).toBeNull();
  });
});
