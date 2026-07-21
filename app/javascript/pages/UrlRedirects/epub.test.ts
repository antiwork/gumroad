// @vitest-environment happy-dom

import { describe, expect, it, vi } from "vitest";

import {
  applyEpubThemeToDocument,
  displayEpubLocation,
  getEpubProgress,
  getEpubThemeRules,
  getEpubContentDocuments,
  getLinearSectionRank,
  removeRemoteEpubResources,
  sanitizeSerializedEpubSection,
} from "./epub";

const location = ({
  section = 0,
  page = 1,
  pageCount = 1,
  atEnd = false,
}: {
  section?: number;
  page?: number;
  pageCount?: number;
  atEnd?: boolean;
} = {}) => ({
  start: { index: section, displayed: { page, total: pageCount } },
  atEnd,
});

describe("getEpubProgress", () => {
  it("uses spine and visible-page progress without parsing hidden sections", () => {
    expect(getEpubProgress(location({ page: 2, pageCount: 4 }), 0, 1)).toBe(25);
    expect(getEpubProgress(location({ section: 2 }), 2, 4)).toBe(50);
  });

  it("uses the linear reading-order rank instead of the raw spine index", () => {
    expect(getEpubProgress(location({ section: 1 }), 0, 2)).toBe(0);
    expect(getEpubProgress(location({ section: 3 }), 1, 2)).toBe(50);
  });

  it("returns 100 only when epub.js reports the visible end", () => {
    expect(getEpubProgress(location(), 0, 1)).toBe(0);
    expect(getEpubProgress(location({ atEnd: true }), 0, 1)).toBe(100);
  });
});

describe("displayEpubLocation", () => {
  it("rejects when epub.js emits displayerror but leaves display pending", async () => {
    const listeners = new Map<string, (error: unknown) => void>();
    const rendition = {
      display: vi.fn(() => new Promise<void>(() => undefined)),
      on: vi.fn((type: string, listener: (error: unknown) => void) => listeners.set(type, listener)),
      off: vi.fn((type: string) => listeners.delete(type)),
    };
    const displayLocation = displayEpubLocation(rendition, "epubcfi(/6/2!)");
    const error = new Error("Spine document is missing");

    listeners.get("displayerror")?.(error);

    await expect(displayLocation).rejects.toBe(error);
    expect(rendition.off).toHaveBeenCalledWith("displayerror", expect.any(Function));
  });
});

describe("getLinearSectionRank", () => {
  it("maps non-linear spine items to their reading-order position", () => {
    expect(getLinearSectionRank(0, [1, 3])).toBe(0);
    expect(getLinearSectionRank(1, [1, 3])).toBe(0);
    expect(getLinearSectionRank(2, [1, 3])).toBe(1);
    expect(getLinearSectionRank(3, [1, 3])).toBe(1);
    expect(getLinearSectionRank(4, [1, 3])).toBe(1);
  });
});

describe("getEpubThemeRules", () => {
  it("scopes important color rules to the body class epub.js applies", () => {
    const rules = getEpubThemeRules("dark", {
      background: "#121212",
      color: "#e6e6e6",
      link: "#8ab4ff",
      surface: "#242424",
    });

    expect(rules["body.dark"]).toEqual({
      "background-color": "#121212 !important",
      color: "#e6e6e6 !important",
    });
    expect(rules["body.dark *"]?.color).toBe("inherit !important");
  });

  it("overrides authored important colors after a section renders", () => {
    document.body.innerHTML = `
      <style>#chapter { color: black !important; background: white !important; }</style>
      <p id="chapter" style="color: black !important; background-color: white !important">Text</p>
    `;

    applyEpubThemeToDocument(document, {
      background: "#121212",
      color: "#e6e6e6",
      link: "#8ab4ff",
      surface: "#242424",
    });

    const chapter = document.querySelector("#chapter");
    expect(chapter).toBeInstanceOf(HTMLElement);
    if (!(chapter instanceof HTMLElement)) throw new Error("Expected an HTML chapter element");
    expect(chapter.style.getPropertyValue("color")).toBe("inherit");
    expect(chapter.style.getPropertyPriority("color")).toBe("important");
    expect(chapter.style.getPropertyValue("background-color")).toBe("transparent");
    expect(chapter.style.getPropertyPriority("background-color")).toBe("important");
  });

  it("overrides authored colors in an iframe document", () => {
    const iframe = document.createElement("iframe");
    document.body.append(iframe);
    const iframeDocument = iframe.contentDocument;
    if (!iframeDocument) throw new Error("Expected an iframe document");
    iframeDocument.body.innerHTML = `<p id="chapter" style="color: black !important">Text</p>`;

    applyEpubThemeToDocument(iframeDocument, {
      background: "#121212",
      color: "#e6e6e6",
      link: "#8ab4ff",
      surface: "#242424",
    });

    const chapter = iframeDocument.querySelector<HTMLElement>("#chapter");
    expect(chapter?.style.getPropertyValue("color")).toBe("inherit");
    expect(chapter?.style.getPropertyPriority("color")).toBe("important");
    iframe.remove();
  });
});

describe("getEpubContentDocuments", () => {
  it("narrows epub.js's incorrect single-content declaration to its runtime array", () => {
    expect(getEpubContentDocuments({ getContents: () => [{ document }, {}] })).toEqual([document]);
    expect(getEpubContentDocuments({ getContents: () => ({ document }) })).toEqual([]);
  });
});

describe("removeRemoteEpubResources", () => {
  it("allows only isolated archive resources while preserving ordinary styles and links", () => {
    document.body.innerHTML = `
      <img id="remote" src="https://tracker.example/pixel.png">
      <img id="same-origin" src="/l/tracked-product?utm_source=epub">
      <img id="packaged" src="blob:packaged-cover">
      <img id="svg-data" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E">
      <video id="video" poster="//tracker.example/poster.png"></video>
      <div id="styled" style="background: url('https://tracker.example/background.png')"></div>
      <style>@import "https://tracker.example/theme.css";</style>
      <p id="safe" style="color: red; background-image: url('/l/tracked-product')">Safe styles</p>
      <style id="safe-style">p { color: red; background-image: url('blob:packaged-paper'); }</style>
      <iframe id="nested" srcdoc="&lt;img src='/l/tracked-product'&gt;"></iframe>
      <object id="embedded" data="data:text/html,&lt;img src='/l/tracked-product'&gt;"></object>
      <meta http-equiv="refresh" content="0;url=https://tracker.example">
      <a id="link" href="https://example.com">Visit source</a>
    `;

    removeRemoteEpubResources(document);

    expect(document.querySelector("#remote")?.hasAttribute("src")).toBe(false);
    expect(document.querySelector("#same-origin")?.hasAttribute("src")).toBe(false);
    expect(document.querySelector("#packaged")?.getAttribute("src")).toBe("blob:packaged-cover");
    expect(document.querySelector("#svg-data")?.getAttribute("src")).toContain("http://www.w3.org/2000/svg");
    expect(document.querySelector("#video")?.hasAttribute("poster")).toBe(false);
    expect(document.querySelector("#styled")?.getAttribute("style")).toContain('url("")');
    expect(document.querySelector("style")?.textContent).not.toContain("tracker.example");
    expect(document.querySelector("#safe")?.getAttribute("style")).toContain("color: red");
    expect(document.querySelector("#safe")?.getAttribute("style")).toContain('url("")');
    expect(document.querySelector("#safe-style")?.textContent).toContain("color: red");
    expect(document.querySelector("#safe-style")?.textContent).toContain("blob:packaged-paper");
    expect(document.querySelector("#nested")).toBeNull();
    expect(document.querySelector("#embedded")).toBeNull();
    expect(document.querySelector("meta")).toBeNull();
    expect(document.querySelector("#link")?.getAttribute("href")).toBe("https://example.com");
  });
});

describe("sanitizeSerializedEpubSection", () => {
  it("runs after archive substitution and keeps packaged blob/data assets", () => {
    const output = `
      <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link id="packaged-style" rel="stylesheet" href="styles.css" />
      </head><body>
        <img id="packaged-image" src="images/cover.png" />
        <img id="same-origin" src="/l/tracked-product" />
      </body></html>
    `;
    const section = {
      output: `
      <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link id="packaged-style" rel="stylesheet" href="blob:packaged-style" />
      </head><body>
        <img id="packaged-image" src="data:image/png;base64,aGVsbG8=" />
        <picture><source id="packaged-responsive" srcset="blob:small 1x, blob:large 2x" /></picture>
        <img id="same-origin" src="/l/tracked-product" />
      </body></html>
    `,
    };

    sanitizeSerializedEpubSection(output, section);

    const document = new DOMParser().parseFromString(section.output, "application/xhtml+xml");
    expect(document.querySelector("#packaged-style")?.getAttribute("href")).toBe("blob:packaged-style");
    expect(document.querySelector("#packaged-image")?.getAttribute("src")).toBe("data:image/png;base64,aGVsbG8=");
    expect(document.querySelector("#packaged-responsive")?.getAttribute("srcset")).toBe("blob:small 1x, blob:large 2x");
    expect(document.querySelector("#same-origin")?.hasAttribute("src")).toBe(false);
    const csp = document.querySelector("meta[http-equiv='Content-Security-Policy']")?.getAttribute("content");
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("img-src blob: data:");
    expect(csp).not.toContain("'self'");
  });

  it("adds a CSP and removes legacy network attributes from a headless section", () => {
    const section = {
      output: `<html xmlns="http://www.w3.org/1999/xhtml"><body background="/l/tracked-product"><p>Text</p></body></html>`,
    };

    sanitizeSerializedEpubSection(section.output, section);

    const document = new DOMParser().parseFromString(section.output, "application/xhtml+xml");
    expect(document.querySelector("head meta[http-equiv='Content-Security-Policy']")).not.toBeNull();
    expect(document.querySelector("body")?.hasAttribute("background")).toBe(false);
  });

  it("moves a late seller-authored head before fetchable markup", () => {
    const section = {
      output: `<html xmlns="http://www.w3.org/1999/xhtml"><body><img srcset="/l/tracked-product 1x" /></body><head><title>Late head</title></head></html>`,
    };

    sanitizeSerializedEpubSection(section.output, section);

    const document = new DOMParser().parseFromString(section.output, "application/xhtml+xml");
    expect(document.documentElement.firstElementChild?.localName).toBe("head");
    expect(document.documentElement.firstElementChild?.firstElementChild?.getAttribute("http-equiv")).toBe(
      "Content-Security-Policy",
    );
    expect(document.querySelector("img")?.getAttribute("srcset")).toBe("/l/tracked-product 1x");
  });
});
