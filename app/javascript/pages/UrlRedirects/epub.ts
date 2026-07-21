export type EpubTheme = {
  background: string;
  color: string;
  link: string;
  surface: string;
};

type EpubDisplay<Target extends string | number> = {
  display: (target?: Target) => Promise<unknown>;
  on: (type: string, listener: (error: unknown) => void) => unknown;
  off: (type: string, listener: (error: unknown) => void) => unknown;
};

type EpubProgressLocation = {
  start: {
    displayed: { page: number; total: number };
  };
  atEnd: boolean;
};

export const getEpubProgress = (
  location: EpubProgressLocation,
  linearSectionIndex: number,
  linearSectionCount: number,
) => {
  if (location.atEnd) return 100;
  // Generating epub.js's content-weighted map decompresses every seller-owned
  // spine document. Use the visible page and reading-order position instead so
  // progress never triggers hidden whole-book work.
  const clampedSectionCount = Math.max(1, linearSectionCount);
  const sectionIndex = Math.max(0, Math.min(linearSectionIndex, clampedSectionCount - 1));
  const displayedPageCount = Math.max(1, location.start.displayed.total);
  const pageIndex = Math.max(0, Math.min(location.start.displayed.page - 1, displayedPageCount - 1));
  const progress = ((sectionIndex + pageIndex / displayedPageCount) / clampedSectionCount) * 100;

  // Completion must come from epub.js's `atEnd` signal. Rounding a position in
  // the final location to 100 would make the download page say "Read again"
  // before the buyer reaches the end of the visible spread.
  return Math.max(0, Math.min(99, Math.floor(progress)));
};

export const getLinearSectionRank = (spineIndex: number, linearSectionIndexes: number[]) => {
  const insertionIndex = linearSectionIndexes.findIndex((index) => index >= spineIndex);
  if (insertionIndex >= 0) return insertionIndex;
  return Math.max(0, linearSectionIndexes.length - 1);
};

// epub.js emits `displayerror` for some rendition failures but leaves the
// promise returned by display() pending. Convert both failure channels into a
// promise that always settles so the reader can show its recovery UI.
export const displayEpubLocation = <Target extends string | number>(rendition: EpubDisplay<Target>, target?: Target) =>
  new Promise<void>((resolve, reject) => {
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) return;
      settled = true;
      rendition.off("displayerror", handleDisplayError);
      callback();
    };
    const handleDisplayError = (error: unknown) => {
      settle(() => reject(error instanceof Error ? error : new Error("Unable to display EPUB")));
    };

    rendition.on("displayerror", handleDisplayError);
    void rendition.display(target).then(
      () => settle(resolve),
      (error: unknown) => handleDisplayError(error),
    );
  });

export const getEpubThemeRules = (
  name: string,
  { background, color, link, surface }: EpubTheme,
): Record<string, Record<string, string>> => ({
  // epub.js adds the selected theme class to the book's body, not its html
  // element. Rule objects also make epub.js inject the active theme when it
  // creates a new iframe; serialized CSS is skipped on that initial pass.
  [`body.${name}`]: {
    "background-color": `${background} !important`,
    color: `${color} !important`,
  },
  [`body.${name} *`]: {
    color: "inherit !important",
    "background-color": "transparent !important",
  },
  [`body.${name} a, body.${name} a:visited`]: {
    color: `${link} !important`,
  },
  [`body.${name} pre, body.${name} code, body.${name} blockquote, body.${name} table, ` +
  `body.${name} th, body.${name} td`]: {
    "background-color": `${surface} !important`,
  },
});

const isSettableStyle = (value: unknown): value is Pick<CSSStyleDeclaration, "setProperty"> => {
  if (typeof value !== "object" || value === null) return false;
  const setProperty: unknown = Reflect.get(value, "setProperty");
  return typeof setProperty === "function";
};

const setImportantStyle = (element: Element, property: string, value: string) => {
  // EPUB contents live in a separate iframe realm, so parent-window
  // HTMLElement/SVGElement instanceof checks reject their elements.
  const style: unknown = Reflect.get(element, "style");
  if (!isSettableStyle(style)) return;
  style.setProperty(property, value, "important");
};

export const applyEpubThemeToDocument = (document: Document, theme: EpubTheme) => {
  const body = document.body;

  setImportantStyle(body, "background-color", theme.background);
  setImportantStyle(body, "color", theme.color);
  for (const element of body.querySelectorAll("*")) {
    setImportantStyle(element, "color", "inherit");
    setImportantStyle(element, "background-color", "transparent");
  }
  for (const element of body.querySelectorAll("a")) setImportantStyle(element, "color", theme.link);
  for (const element of body.querySelectorAll("pre, code, blockquote, table, th, td")) {
    setImportantStyle(element, "background-color", theme.surface);
  }
};

const isUnknownArray = (value: unknown): value is unknown[] => Array.isArray(value);

const isEpubContentDocument = (value: unknown): value is Document => {
  if (typeof value !== "object" || value === null) return false;
  const querySelectorAll: unknown = Reflect.get(value, "querySelectorAll");
  const body: unknown = Reflect.get(value, "body");
  return typeof querySelectorAll === "function" && typeof body === "object" && body !== null;
};

export const getEpubContentDocuments = (rendition: { getContents: () => unknown }) => {
  const contents = rendition.getContents();
  if (!isUnknownArray(contents)) return [];

  return contents.flatMap((content): Document[] => {
    if (typeof content !== "object" || content === null || !("document" in content)) return [];
    const contentDocument: unknown = Reflect.get(content, "document");
    return isEpubContentDocument(contentDocument) ? [contentDocument] : [];
  });
};

const cssImportPattern = /@import\s+(["'])(.*?)\1[^;]*;?/giu;
const cssUrlPattern = /url\(\s*(["']?)(.*?)\1\s*\)/giu;

// Resource replacement turns files from the EPUB archive into blob/data URLs.
// Any unresolved path could instead hit the Gumroad or seller custom domain,
// so only already isolated URLs and same-document SVG fragments are safe.
const isIsolatedEpubResource = (value: string) => /^(?:blob:|data:|#)/iu.test(value.trim());

const removeRemoteCssResources = (css: string) =>
  css
    .replace(cssImportPattern, (rule: string, _quote: string, url: string) => (isIsolatedEpubResource(url) ? rule : ""))
    .replace(cssUrlPattern, (rule: string, _quote: string, url: string) =>
      isIsolatedEpubResource(url) ? rule : 'url("")',
    );

const resourceAttributes = [
  ["[src]", "src"],
  ["[poster]", "poster"],
  [
    "body[background], table[background], thead[background], tbody[background], tfoot[background], tr[background], th[background], td[background]",
    "background",
  ],
  ["object[data]", "data"],
  ["link[href]", "href"],
  ["image[href], use[href], feImage[href]", "href"],
  ["image[xlink\\:href], use[xlink\\:href], feImage[xlink\\:href]", "xlink:href"],
] as const;

const epubDocumentCsp = [
  "default-src 'none'",
  "img-src blob: data:",
  "media-src blob: data:",
  "font-src blob: data:",
  "style-src 'unsafe-inline' blob: data:",
  "object-src 'none'",
  "frame-src 'none'",
  "child-src 'none'",
  "connect-src 'none'",
  "script-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

const addEpubDocumentCsp = (document: Document) => {
  const namespace = document.documentElement.namespaceURI ?? "http://www.w3.org/1999/xhtml";
  let root: Element = document.documentElement;
  if (root.localName !== "html") {
    const originalRoot = root;
    root = document.createElementNS(namespace, "html");
    const body = document.createElementNS(namespace, "body");
    document.replaceChild(root, originalRoot);
    body.appendChild(originalRoot);
    root.appendChild(body);
  }
  let head: Element | null = document.querySelector("head");
  if (!head) {
    head = document.createElementNS(namespace, "head");
  }
  // A seller can place an existing head after fetchable body markup. Move it
  // before every other node so the browser sees the CSP before parsing srcset.
  root.prepend(head);

  const meta = document.createElementNS(namespace, "meta");
  meta.setAttribute("http-equiv", "Content-Security-Policy");
  meta.setAttribute("content", epubDocumentCsp);
  head.prepend(meta);
};

// epub.js disables scripts in the book iframe, but the browser still fetches
// images, media, styles, and frames found in seller-authored markup. Resource
// replacement has already isolated valid archive files as data/blob URLs. The
// document CSP below is the network boundary; this cleanup also removes unsafe
// markup before the browser creates the iframe.
export const removeRemoteEpubResources = (document: Document) => {
  // Nested documents have their own parser and can hide automatic requests in
  // srcdoc or data-backed HTML. EPUB reading does not require active frames or
  // embedded objects, so remove those contexts instead of trying to recurse.
  for (const element of document.querySelectorAll("iframe, frame, object, embed, portal")) element.remove();

  for (const [selector, attribute] of resourceAttributes) {
    for (const element of document.querySelectorAll(selector)) {
      const value = element.getAttribute(attribute);
      if (value && !isIsolatedEpubResource(value)) element.removeAttribute(attribute);
    }
  }

  // Keep responsive packaged images intact. The document CSP is the trust
  // boundary for srcset because data-URI commas make string-level candidate
  // parsing unsafe; it permits only blob/data image loads.

  for (const element of document.querySelectorAll("[style]")) {
    const value = element.getAttribute("style");
    if (!value) continue;
    const sanitized = removeRemoteCssResources(value);
    if (sanitized.trim()) element.setAttribute("style", sanitized);
    else element.removeAttribute("style");
  }

  for (const style of document.querySelectorAll("style")) {
    if (style.textContent) style.textContent = removeRemoteCssResources(style.textContent);
  }

  for (const meta of document.querySelectorAll("meta[http-equiv]")) {
    if (meta.getAttribute("http-equiv")?.toLowerCase() === "refresh") meta.remove();
  }
};

type SerializedEpubSection = { output: string };

// epub.js runs spine serialize hooks in registration order. Its own resource
// hook first converts valid archive paths to blob/data URLs; this hook then
// removes anything still capable of reaching a network origin.
export const sanitizeSerializedEpubSection = (output: string, section: SerializedEpubSection) => {
  // Hook arguments are shared, but epub.js's substitution hook writes its
  // result to section.output. Read that mutation so archive URLs have already
  // become blob/data URLs before we decide which resources are safe.
  const document = new DOMParser().parseFromString(section.output || output, "application/xhtml+xml");
  removeRemoteEpubResources(document);
  addEpubDocumentCsp(document);
  section.output = new XMLSerializer().serializeToString(document);
};
