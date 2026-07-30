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

  // The cap on a LANDSCAPE frame is what shrank every cover on afetop.gumroad.com: the
  // derived height of a 16:9 cover in the product column exceeds 80svh in any window
  // shorter than ~800px, the frame goes shorter than its ratio, and `object-contain`
  // then shrinks the cover in both axes — measured 142px of empty background either
  // side of a 1280x720 cover at 1440x700. Nothing needs capping here: a landscape
  // frame's height never exceeds the column width.
  // See https://github.com/antiwork/gumroad-private/issues/1570
  it("does not cap the height of a landscape frame, which would pillarbox the cover", () => {
    const { container } = renderCovers([cover({ native_width: 1280, native_height: 720 })]);

    expect(frame(container)?.style.aspectRatio).toBe("1280 / 720");
    expect(frame(container)?.style.maxHeight).toBe("");
  });

  // A square cover derives a height equal to the column width, so it has the same
  // no-runaway property as landscape and must not be capped either. It is called out
  // separately because `height > width` is the boundary the cap turns on.
  it("does not cap the height of a square frame", () => {
    const { container } = renderCovers([cover({ native_width: 1000, native_height: 1000 })]);

    expect(frame(container)?.style.aspectRatio).toBe("1000 / 1000");
    expect(frame(container)?.style.maxHeight).toBe("");
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

  // The player is created once (deps `[id]`), so it captures its sizing mode at mount while
  // the box around it re-renders. If that mode depended on the FRAME being shaped, a video
  // sibling of a dimension-less active cover would be built with fixed mount-time pixels and
  // keep them after the buyer navigates to it and the box became ratio-sized and capped --
  // spilling out of the box and inflating the carousel's scrollable width.
  it("sizes a video player from its own ratio even while the active cover leaves the frame unshaped", async () => {
    renderCovers(
      [cover({ id: "no-dimensions", native_width: null, native_height: null }), portrait({ id: "sibling" })],
      "no-dimensions",
    );

    await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
    const options = createJWPlayer.mock.calls[0]?.[1];
    expect(options).toMatchObject({ width: "100%", aspectratio: "1080:1920" });
    expect(options).not.toHaveProperty("height");
  });

  // Zero is a real legacy value -- an old oEmbed row storing "auto" parses to 0 -- so the
  // guards check falsiness rather than `!== null`. Every other dimension-less example here
  // uses null, which would still pass if a guard were tightened to a null check.
  it("leaves the frame unshaped when the active cover reports zero dimensions", () => {
    const { container } = renderCovers([cover({ native_width: 0, native_height: 0 })]);

    expect(frame(container)?.style.aspectRatio).toBe("");
    expect(frame(container)?.style.maxHeight).toBe("");
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

  // JW Player's docs are explicit that `aspectratio` is ignored when the player has a
  // static pixel size, and that `height` should be omitted alongside it. Passing both
  // left the fix depending on undocumented precedence.
  it("does not also pin the player to a fixed pixel size when it sends a ratio", async () => {
    renderCovers([portrait()]);

    await waitFor(() => expect(createJWPlayer).toHaveBeenCalled());
    const options = createJWPlayer.mock.calls[0]?.[1];
    expect(options).toMatchObject({ width: "100%" });
    expect(options).not.toHaveProperty("height");
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

  // The panel has to fill the frame's capped height, or the cover overflows past the
  // bottom of the figure — but only when the frame HAS a definite height to fill.
  it("gives the cover panel the frame's height only when the frame is shaped", () => {
    const { container: shaped } = renderCovers([portrait()]);
    expect(shaped.querySelector("[role=tabpanel]")?.className).toContain("h-full");

    cleanup();
    const { container: unshaped } = renderCovers([cover({ native_width: null, native_height: null })]);
    expect(unshaped.querySelector("[role=tabpanel]")?.className).not.toContain("h-full");
  });

  // Once the frame is shaped, the cover can be narrower than it (the height cap), so
  // the decorative tiled artwork behind it becomes visible and reads as a glitch.
  it("drops the tiled placeholder artwork behind a shaped frame and keeps it otherwise", () => {
    renderCovers([portrait()]);
    expect(screen.getByLabelText("Product preview").className).toContain("bg-background");
    expect(screen.getByLabelText("Product preview").className).not.toContain("product-cover-placeholder");

    cleanup();
    renderCovers([cover({ native_width: null, native_height: null })]);
    expect(screen.getByLabelText("Product preview").className).toContain("product-cover-placeholder");
  });

  // A `height: 100%` box inside a frame with no definite height resolves to auto and,
  // with only an aspect ratio to go on, collapses to nothing. That happens to a sibling
  // cover whenever the ACTIVE cover has no recorded dimensions.
  it("keeps the width-derived box for a sibling cover while the frame is unshaped", () => {
    const { container } = renderCovers(
      [cover({ id: "no-dimensions", native_width: null, native_height: null }), cover({ id: "sibling" })],
      "no-dimensions",
    );
    const siblingBox = container.querySelector<HTMLElement>("#sibling > div");

    expect(siblingBox?.style.paddingBottom).not.toBe("");
    expect(siblingBox?.style.height).toBe("");
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
