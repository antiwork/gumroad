// @vitest-environment happy-dom
// epub.js does not publish declarations for its internal cleanup classes. We
// import them here so patch-package regressions exercise the code we ship.
import Archive, { MAX_EPUB_ARCHIVE_BYTES, MAX_EPUB_ENTRY_COUNT } from "epubjs/src/archive";
import DefaultViewManager from "epubjs/src/managers/default";
import Rendition from "epubjs/src/rendition";
import Resources from "epubjs/src/resources";
import Queue from "epubjs/src/utils/queue";
import JSZip from "jszip";
import { afterEach, describe, expect, it, vi } from "vitest";

describe("epub.js resource cleanup patch", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("revokes an archive blob created after destroy", async () => {
    const createObjectURL = vi.fn(() => "blob:late-asset");
    const revokeObjectURL = vi.fn();
    vi.stubGlobal("URL", { createObjectURL, revokeObjectURL });
    let resolveBlob: (blob: Blob) => void = () => undefined;
    const blob = new Promise<Blob>((resolve) => {
      resolveBlob = resolve;
    });
    const archive = new Archive();
    vi.spyOn(archive, "getBlob").mockReturnValue(blob);

    const pendingUrl = archive.createUrl("/image.png");
    archive.destroy();
    resolveBlob(new Blob(["image"]));

    await expect(pendingUrl).resolves.toBe("blob:late-asset");
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:late-asset");
    expect(archive.urlCache).toEqual({});
  });

  it("propagates corrupt ZIP entry failures from archive requests", async () => {
    const archive = new Archive();
    const error = new Error("CRC check failed");
    vi.spyOn(archive, "getText").mockRejectedValue(error);

    await expect(archive.request("/chapter.xhtml", "xhtml")).rejects.toBe(error);
  });

  it("propagates corrupt ZIP entry failures while creating resource URLs", async () => {
    const archive = new Archive();
    const error = new Error("Decompression failed");
    vi.spyOn(archive, "getBlob").mockRejectedValue(error);

    await expect(archive.createUrl("/cover.png")).rejects.toBe(error);
  });

  it("rejects a compressed archive above the reader memory limit", async () => {
    const archive = new Archive();
    const loadAsync = vi.spyOn(archive.zip, "loadAsync");

    await expect(archive.open({ byteLength: MAX_EPUB_ARCHIVE_BYTES + 1 })).rejects.toThrow(
      "EPUB archive exceeds the reader memory limit",
    );
    expect(loadAsync).not.toHaveBeenCalled();
  });

  it("rejects excessive entry counts before JSZip parses them", async () => {
    const archive = new Archive();
    const loadAsync = vi.spyOn(archive.zip, "loadAsync");
    const entryCount = MAX_EPUB_ENTRY_COUNT + 1;
    const directoryBytes = entryCount * 46;
    const input = new Uint8Array(directoryBytes + 22);
    const view = new DataView(input.buffer);
    for (let offset = 0; offset < directoryBytes; offset += 46) view.setUint32(offset, 0x02014b50, true);
    view.setUint32(directoryBytes, 0x06054b50, true);
    view.setUint16(directoryBytes + 8, entryCount, true);
    view.setUint16(directoryBytes + 10, entryCount, true);
    view.setUint32(directoryBytes + 12, directoryBytes, true);

    await expect(archive.open(input)).rejects.toThrow("EPUB contains too many ZIP entries");
    expect(loadAsync).not.toHaveBeenCalled();
  });

  it("does not count central-directory signatures stored inside a file", async () => {
    const signaturePayload = "PK\u0001\u0002".repeat(MAX_EPUB_ENTRY_COUNT + 1);
    const input = await new JSZip()
      .file("nested-signatures.bin", signaturePayload, { compression: "STORE" })
      .generateAsync({ type: "uint8array" });

    await expect(new Archive().open(input)).resolves.toBeDefined();
  });

  it("bounds each entry by bytes emitted during inflation", async () => {
    const input = await new JSZip().file("chapter.xhtml", "four").generateAsync({ type: "uint8array" });
    const archive = new Archive();
    archive.maxEntryBytes = 3;
    await archive.open(input);

    await expect(archive.getText("/chapter.xhtml")).rejects.toThrow("EPUB contains an oversized ZIP entry");
  });

  it("bounds aggregate bytes emitted across inflated entries", async () => {
    const input = await new JSZip().file("one.txt", "12").file("two.txt", "34").generateAsync({ type: "uint8array" });
    const archive = new Archive();
    archive.maxExpandedBytes = 3;
    await archive.open(input);

    await expect(archive.getText("/one.txt")).resolves.toBe("12");
    await expect(archive.getText("/two.txt")).rejects.toThrow("EPUB expands beyond the reader memory limit");
  });

  it("preserves replacement indexes when one archive asset fails", async () => {
    const resources = new Resources(
      {
        broken: { href: "images/broken.png", type: "image/png" },
        valid: { href: "images/valid.png", type: "image/png" },
      },
      {
        archive: { getText: () => Promise.resolve("") },
        replacements: "blobUrl",
        resolver: (href: string) => href,
      },
    );
    vi.spyOn(resources, "createUrl")
      .mockRejectedValueOnce(new Error("Broken asset"))
      .mockResolvedValueOnce("blob:valid-asset");

    await resources.replacements();

    expect(resources.replacementUrls).toEqual([null, "blob:valid-asset"]);
    expect(resources.substitute("images/broken.png images/valid.png")).toBe("images/broken.png blob:valid-asset");
  });

  it("does not create a stylesheet blob after resources are destroyed", async () => {
    const createObjectURL = vi.fn(() => "blob:late-stylesheet");
    const revokeObjectURL = vi.fn();
    vi.stubGlobal("URL", { createObjectURL, revokeObjectURL });
    let resolveText: (text: string) => void = () => undefined;
    const text = new Promise<string>((resolve) => {
      resolveText = resolve;
    });
    const resources = new Resources(
      { stylesheet: { href: "styles.css", type: "text/css" } },
      {
        archive: { getText: () => text },
        replacements: "blobUrl",
        resolver: (href: string) => href,
      },
    );

    const pendingUrl = resources.createCssFile("styles.css");
    resources.destroy();
    resolveText("body { color: red; }");

    await expect(pendingUrl).resolves.toBeUndefined();
    expect(createObjectURL).not.toHaveBeenCalled();
    expect(revokeObjectURL).not.toHaveBeenCalled();
  });

  it("removes unresolved network and same-origin URLs from packaged CSS", async () => {
    const resources = new Resources(
      { stylesheet: { href: "styles.css", type: "text/css" } },
      {
        archive: {
          getText: () =>
            Promise.resolve(`
              @import url('/l/tracked-product');
              .remote { background-image: url('https://tracker.example/pixel.png'); }
              .same-origin { background-image: url('/l/tracked-product'); }
              .packaged { background-image: url('blob:packaged-image'); }
              .inline { background-image: url('data:image/png;base64,aGVsbG8='); }
            `),
        },
        replacements: "base64",
        resolver: (href: string) => href,
      },
    );

    const stylesheetUrl = await resources.createCssFile("styles.css");
    if (!stylesheetUrl) throw new Error("Expected a generated stylesheet URL");
    const encodedCss = stylesheetUrl.split(",")[1];
    if (!encodedCss) throw new Error("Expected a base64 stylesheet URL");
    const css = atob(encodedCss);
    expect(css).not.toContain("tracked-product");
    expect(css).not.toContain("tracker.example");
    expect(css).toContain("blob:packaged-image");
    expect(css).toContain("data:image/png;base64,aGVsbG8=");
  });
});

describe("epub.js navigation error patch", () => {
  const buildManager = () => {
    const adjacentSection = { next: () => undefined, prev: () => undefined, properties: [] };
    const currentSection = {
      next: () => adjacentSection,
      prev: () => adjacentSection,
      properties: [],
    };
    const manager = new DefaultViewManager({
      queue: {},
      request: () => Promise.resolve(),
      settings: { axis: "horizontal" },
      view: class {
        readonly epubView = true;
      },
    });
    manager.clear = vi.fn();
    manager.isPaginated = false;
    manager.layout = { divisor: 1, name: "reflowable" };
    manager.updateLayout = vi.fn();
    manager.views = {
      find: () => undefined,
      first: () => ({ section: currentSection }),
      last: () => ({ section: currentSection }),
      length: 1,
      show: vi.fn(),
    };
    return manager;
  };

  it("rejects when the next section fails to load", async () => {
    const manager = buildManager();
    const error = new Error("Next section is corrupt");
    manager.append = vi.fn(() => Promise.reject(error));

    await expect(manager.next()).rejects.toBe(error);
    expect(manager.views.show).not.toHaveBeenCalled();
  });

  it("rejects when the previous section fails to load", async () => {
    const manager = buildManager();
    const error = new Error("Previous section is corrupt");
    manager.prepend = vi.fn(() => Promise.reject(error));

    await expect(manager.prev()).rejects.toBe(error);
    expect(manager.views.show).not.toHaveBeenCalled();
  });

  it("rejects display when an adjacent pre-paginated section fails to load", async () => {
    const manager = buildManager();
    const error = new Error("Adjacent spread section is corrupt");
    const adjacentSection = { next: () => undefined, prev: () => undefined, properties: [] };
    const section = {
      href: "chapter-2.xhtml",
      index: 1,
      next: () => adjacentSection,
      prev: () => undefined,
      properties: [],
    };
    manager.layout = { divisor: 2, name: "pre-paginated" };
    manager.add = vi.fn().mockResolvedValueOnce({}).mockRejectedValueOnce(error);

    await expect(manager.display(section)).rejects.toBe(error);
    expect(manager.views.show).not.toHaveBeenCalled();
  });

  it("stops the display chain when the initial section fails to load", async () => {
    const manager = buildManager();
    const error = new Error("Initial section is corrupt");
    const section = {
      href: "chapter-1.xhtml",
      index: 1,
      next: () => ({ next: () => undefined, prev: () => undefined, properties: [] }),
      prev: () => undefined,
      properties: [],
    };
    manager.add = vi.fn(() => Promise.reject(error));

    await expect(manager.display(section)).rejects.toBe(error);
    expect(manager.add).toHaveBeenCalledOnce();
    expect(manager.views.show).not.toHaveBeenCalled();
  });
});

describe("epub.js rendition error patch", () => {
  it("rejects when a malformed CFI throws synchronously", async () => {
    const error = new Error("Invalid CFI path");
    const rendition = {
      book: {
        locations: { length: () => 0 },
        spine: {
          get: () => {
            throw error;
          },
        },
      },
      emit: vi.fn(),
      epubcfi: { isCfiString: () => true },
    };
    Object.setPrototypeOf(rendition, Rendition.prototype);

    await expect(Rendition.prototype._display.call(rendition, "epubcfi(/6/4!)")).rejects.toBe(error);
    expect(rendition.emit).toHaveBeenCalledWith("displayerror", error);
  });

  it("settles a failed display so a fallback display can complete", async () => {
    const error = new Error("Stored section is corrupt");
    const section = { href: "chapter.xhtml" };
    const rendition = {
      book: {
        locations: { length: () => 0 },
        spine: { get: () => section },
      },
      emit: vi.fn(),
      epubcfi: { isCfiString: () => false },
      manager: { display: vi.fn().mockRejectedValueOnce(error).mockResolvedValueOnce(undefined) },
      q: new Queue({}),
      reportLocation: vi.fn(),
    };
    Object.setPrototypeOf(rendition, Rendition.prototype);
    rendition.q = new Queue(rendition);

    await expect(Rendition.prototype.display.call(rendition, "epubcfi(/6/4!)")).rejects.toBe(error);
    await expect(Rendition.prototype.display.call(rendition)).resolves.toBe(section);
  });
});
