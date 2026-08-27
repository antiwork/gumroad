// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from "vitest";

import { isLikelyImageFile, prepareImageForUpload, heicDecodingLikely } from "$app/utils/prepareImageForUpload";
import { installFileDropNavigationGuard } from "$app/utils/preventFileDropNavigation";

describe("isLikelyImageFile", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("treats HEIC as an image only when the browser can decode it", () => {
    vi.stubGlobal("navigator", {
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    });
    expect(heicDecodingLikely()).toBe(true);
    expect(isLikelyImageFile(new File([""], "photo.HEIC"))).toBe(true);
    vi.stubGlobal("navigator", {
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    });
    expect(heicDecodingLikely()).toBe(false);
    expect(isLikelyImageFile(new File([""], "photo.HEIC"))).toBe(false);
    expect(isLikelyImageFile(new File([""], "shot.avif"))).toBe(true);
    expect(isLikelyImageFile(new File([""], "notes.pdf", { type: "application/pdf" }))).toBe(false);
    expect(isLikelyImageFile(new File(["<svg></svg>"], "logo.svg", { type: "image/svg+xml" }))).toBe(false);
  });
});

describe("prepareImageForUpload", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("leaves a small JPEG alone", async () => {
    const file = new File(["jpeg-bytes"], "cover.jpg", { type: "image/jpeg" });
    const close = vi.fn();
    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(() => Promise.resolve({ width: 800, height: 600, close })),
    );

    const result = await prepareImageForUpload(file, { maxBytes: 5 * 1024 * 1024 });

    expect(result).toBe(file);
    expect(close).toHaveBeenCalled();
  });

  it("converts HEIC to JPEG and resizes when the source is too large", async () => {
    vi.stubGlobal("navigator", {
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    });
    const file = new File(["heic-bytes"], "photo.heic", { type: "" });
    const close = vi.fn();
    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(() => Promise.resolve({ width: 8000, height: 6000, close })),
    );
    const toBlob = vi.fn((cb: BlobCallback) => {
      cb(new Blob([new Uint8Array(1200)], { type: "image/jpeg" }));
    });
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation(toBlob);
    // happy-dom's canvas.getContext("2d") is null; this helper only calls drawImage.
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
      { drawImage: vi.fn() } as unknown as CanvasRenderingContext2D,
    );

    const result = await prepareImageForUpload(file, { maxBytes: 5 * 1024 * 1024, maxDimension: 4096 });

    expect(result).not.toBe(file);
    expect(result.name).toBe("photo.jpg");
    expect(result.type).toBe("image/jpeg");
    expect(toBlob).toHaveBeenCalled();
    expect(close).toHaveBeenCalled();
  });
});

describe("installFileDropNavigationGuard", () => {
  it("prevents the browser from navigating when a file is dropped on the page", () => {
    const doc = document;
    const uninstall = installFileDropNavigationGuard(doc);
    const event = new DragEvent("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "dataTransfer", { value: { types: ["Files"], files: [] } });

    doc.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    uninstall();
  });
});
