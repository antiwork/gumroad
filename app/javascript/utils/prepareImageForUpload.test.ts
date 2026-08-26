// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from "vitest";

import { isLikelyImageFile, prepareImageForUpload } from "$app/utils/prepareImageForUpload";
import { installFileDropNavigationGuard } from "$app/utils/preventFileDropNavigation";

describe("isLikelyImageFile", () => {
  it("treats HEIC and AVIF as images even when the MIME type is empty", () => {
    expect(isLikelyImageFile(new File([""], "photo.HEIC"))).toBe(true);
    expect(isLikelyImageFile(new File([""], "shot.avif"))).toBe(true);
    expect(isLikelyImageFile(new File([""], "notes.pdf", { type: "application/pdf" }))).toBe(false);
  });
});

describe("prepareImageForUpload", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("leaves a small JPEG alone", async () => {
    const file = new File(["jpeg-bytes"], "cover.jpg", { type: "image/jpeg" });
    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(async () => ({ width: 800, height: 600, close: vi.fn() })),
    );

    const result = await prepareImageForUpload(file, { maxBytes: 5 * 1024 * 1024 });

    expect(result).toBe(file);
  });

  it("converts HEIC to JPEG and resizes when the source is too large", async () => {
    const file = new File(["heic-bytes"], "photo.heic", { type: "" });
    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(async () => ({ width: 8000, height: 6000, close: vi.fn() })),
    );
    const toBlob = vi.fn((cb: (blob: Blob | null) => void) => {
      cb(new Blob([new Uint8Array(1200)], { type: "image/jpeg" }));
    });
    const origCreate = document.createElement.bind(document);
    vi.spyOn(document, "createElement").mockImplementation((tag: string) => {
      if (tag !== "canvas") return origCreate(tag);
      return {
        width: 0,
        height: 0,
        getContext: () => ({ drawImage: vi.fn() }),
        toBlob,
      } as unknown as HTMLCanvasElement;
    });

    const result = await prepareImageForUpload(file, { maxBytes: 5 * 1024 * 1024, maxDimension: 4096 });

    expect(result).not.toBe(file);
    expect(result.name).toBe("photo.jpg");
    expect(result.type).toBe("image/jpeg");
    expect(toBlob).toHaveBeenCalled();
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
