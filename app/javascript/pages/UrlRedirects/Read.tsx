import { ArrowLeft, ArrowRight, SearchMinus, SearchPlus, X } from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import type { Book, Rendition, Location as EpubLocation } from "epubjs";
import type { PDFSinglePageViewer } from "pdfjs-dist/legacy/web/pdf_viewer.mjs";
import * as React from "react";
import typia from "typia";

import { trackMediaLocationChanged } from "$app/data/media_location";
import {
  applyEpubThemeToDocument,
  displayEpubLocation,
  getEpubContentDocuments,
  getEpubProgress,
  getEpubThemeRules,
  getLinearSectionRank,
  sanitizeSerializedEpubSection,
} from "$app/pages/UrlRedirects/epub";

import { Button } from "$app/components/Button";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Range } from "$app/components/ui/Range";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";
import "pdfjs-dist/legacy/web/pdf_viewer.css";

const zoomLevelMin = 0.1;
const zoomLevelMax = 5.0;

type Props = {
  read_id: string;
  url: string;
  url_redirect_id: string;
  purchase_id: string | null;
  product_file_id: string;
  latest_media_location: {
    location: number;
    timestamp: string;
    cfi?: string | null;
    unit?: "page_number" | "percentage" | "seconds";
  } | null;
  title: string;
  file_type: "pdf" | "epub";
};

export const MAX_EPUB_ARCHIVE_BYTES = 32 * 1024 * 1024;

export const downloadEpubArchive = async (
  url: string,
  signal: AbortSignal,
  maxBytes = MAX_EPUB_ARCHIVE_BYTES,
): Promise<ArrayBuffer> => {
  const response = await fetch(url, { signal });
  if (!response.ok || !response.body) throw new Error("EPUB download failed");

  const contentLength = response.headers.get("content-length");
  const declaredBytes = Number(contentLength);
  if (contentLength == null || !Number.isSafeInteger(declaredBytes) || declaredBytes <= 0) {
    await response.body.cancel();
    throw new Error("EPUB download size is unavailable");
  }
  if (declaredBytes > maxBytes) {
    await response.body.cancel();
    throw new Error("EPUB archive exceeds the reader memory limit");
  }

  const reader = response.body.getReader();
  const archive = new Uint8Array(declaredBytes);
  let totalBytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (totalBytes + value.byteLength > maxBytes) {
        await reader.cancel();
        throw new Error("EPUB archive exceeds the reader memory limit");
      }
      if (totalBytes + value.byteLength > declaredBytes) {
        await reader.cancel();
        throw new Error("EPUB download size did not match storage metadata");
      }
      archive.set(value, totalBytes);
      totalBytes += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }

  if (totalBytes !== declaredBytes) throw new Error("EPUB download was incomplete");
  return archive.buffer;
};

const getCurrentEpubLocation = (rendition: Rendition): EpubLocation | null => {
  // epub.js types this as always present, but it is undefined until the first
  // relocation event for some books and rendering modes.
  const location: unknown = Reflect.get(rendition, "location");
  return typia.is<EpubLocation>(location) ? location : null;
};

// The reading position we persist in a cookie so an anonymous (or same-browser)
// reader can pick up where they left off. For PDFs `location` is a page number;
// for EPUBs it is progress from 0 through 100 and `cfi` stores the exact
// position (an EPUB Canonical Fragment Identifier).
type StoredMediaLocation = {
  timestamp?: string | null;
  location?: number | null;
  cfi?: string | null;
  unit?: "page_number" | "percentage" | "seconds";
};

export const canResumePdfFromLocation = (location: StoredMediaLocation) =>
  location.location != null && (location.unit === "page_number" || (location.unit == null && location.cfi == null));

const getMediaLocationFromCookies = (readId: string): StoredMediaLocation => {
  const cookieValue = document.cookie
    .split("; ")
    .find((row) => row.startsWith(`${encodeURIComponent(readId)}=`))
    ?.split("=")
    .slice(1)
    .join("=");
  if (cookieValue) {
    try {
      const json: unknown = JSON.parse(decodeURIComponent(cookieValue));
      if (typia.is<StoredMediaLocation>(json)) return json;
    } catch {
      // Ignore cookies we can't parse — e.g. ones written before values were
      // URI-encoded, or ones truncated by the browser. Resuming from the server
      // location (or the start) is better than crashing the read page.
    }
  }
  return {};
};

const Read = () => {
  const props = typia.assert<Props>(usePage().props);
  return props.file_type === "epub" ? <EpubReader {...props} /> : <PdfReader {...props} />;
};

const PdfReader = ({
  read_id,
  url,
  url_redirect_id,
  purchase_id,
  product_file_id,
  latest_media_location,
  title,
}: Props) => {
  const [pageNumber, setPageNumber] = React.useState(1);
  const [pageCount, setPageCount] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(true);
  const [pageTooltip, setPageTooltip] = React.useState<{ left: number; pageNumber: number } | null>(null);
  const contentRef = React.useRef<HTMLDivElement>(null);
  const pdfViewerRef = React.useRef<PDFSinglePageViewer | null>(null);

  const updatePage = React.useCallback(
    (val: "previous" | "next" | number, pages: number = pageCount) => {
      let newPageNumber = pageNumber;
      if (val === "next") {
        newPageNumber += 1;
      } else if (val === "previous") {
        newPageNumber -= 1;
      } else {
        newPageNumber = val;
      }
      newPageNumber = Math.max(1, Math.min(newPageNumber, pages));
      setPageNumber(newPageNumber);
      if (pdfViewerRef.current) {
        pdfViewerRef.current.currentPageNumber = newPageNumber;
      }
      if (purchase_id) {
        void trackMediaLocationChanged({
          urlRedirectId: url_redirect_id,
          productFileId: product_file_id,
          purchaseId: purchase_id,
          location: newPageNumber,
        });
      }
      document.cookie = `${encodeURIComponent(read_id)}=${encodeURIComponent(
        JSON.stringify({
          location: newPageNumber,
          timestamp: new Date(),
        }),
      )}`;
    },
    [pageNumber, pageCount, purchase_id, url_redirect_id, product_file_id, read_id],
  );

  const zoomIn = () => {
    if (!pdfViewerRef.current) return;
    const newScale = Math.min(zoomLevelMax, Math.ceil(pdfViewerRef.current.currentScale * 1.1 * 10) / 10);
    pdfViewerRef.current.currentScaleValue = newScale.toString();
  };

  const zoomOut = () => {
    if (!pdfViewerRef.current) return;
    const newScale = Math.max(zoomLevelMin, Math.floor((pdfViewerRef.current.currentScale / 1.1) * 10) / 10);
    pdfViewerRef.current.currentScaleValue = newScale.toString();
  };

  useRunOnce(() => {
    const resumeFromLastLocation = (pageCount: number) => {
      const storedCookieLocation = getMediaLocationFromCookies(read_id);
      const latestMediaLocationFromCookies = canResumePdfFromLocation(storedCookieLocation) ? storedCookieLocation : {};

      if (
        latest_media_location &&
        (!latestMediaLocationFromCookies.timestamp ||
          new Date(latest_media_location.timestamp) > new Date(latestMediaLocationFromCookies.timestamp))
      ) {
        const location = latest_media_location.location;
        updatePage(location >= pageCount ? 1 : location, pageCount);
      } else if (latestMediaLocationFromCookies.location != null) {
        const location = latestMediaLocationFromCookies.location;
        updatePage(location >= pageCount ? 1 : location, pageCount);
      } else {
        updatePage(1, pageCount);
      }
    };

    const showDocument = async () => {
      if (!contentRef.current) return;

      const container = contentRef.current;

      const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
      pdfjs.GlobalWorkerOptions.workerSrc = typia.assert<{ default: string }>(
        // @ts-expect-error pdfjs-dist worker is not typed
        await import("pdfjs-dist/legacy/build/pdf.worker.mjs?url"),
      ).default;

      const { EventBus, PDFLinkService, PDFSinglePageViewer } = await import("pdfjs-dist/legacy/web/pdf_viewer.mjs");
      const eventBus = new EventBus();
      const pdfLinkService = new PDFLinkService({ eventBus });
      const pdfSinglePageViewer = new PDFSinglePageViewer({ container, eventBus, linkService: pdfLinkService });
      pdfLinkService.setViewer(pdfSinglePageViewer);
      pdfViewerRef.current = pdfSinglePageViewer;

      eventBus.on("pagesinit", () => {
        pdfSinglePageViewer.currentScaleValue = "page-fit";
        setIsLoading(false);
        resumeFromLastLocation(pdfViewerRef.current?.pdfDocument?.numPages ?? 1);
      });
      eventBus.on("pagerender", () => {
        const page = container.querySelector(".page");
        if (page instanceof HTMLElement) {
          page.style.border = "revert";
        }
      });

      const pdf = await pdfjs.getDocument(url).promise;
      setPageCount(pdf.numPages);
      pdfSinglePageViewer.setDocument(pdf);
      pdfLinkService.setDocument(pdf, null);
    };
    void showDocument();
  });

  React.useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft") {
        updatePage("previous");
      } else if (e.key === "ArrowRight") {
        updatePage("next");
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [updatePage]);

  return (
    <div style={{ display: "contents" }}>
      {isLoading ? <ReaderLoadingOverlay /> : null}
      <div role="application" className="scoped-tailwind-preflight flex min-h-screen flex-col">
        <div role="menubar" className="flex text-sm md:text-base">
          <div className="border-r">
            <button aria-label="Back" onClick={() => history.back()} className="cursor-pointer p-4 all-unset">
              <X className="size-5" />
            </button>
          </div>
          <div className="flex flex-1 items-center border-r p-4">
            <h1 className="truncate">{title}</h1>
          </div>
          <Popover>
            <PopoverTrigger aria-label="Appearance" className="border-r p-4">
              <SearchPlus className="size-5" />
            </PopoverTrigger>
            <PopoverContent>
              <Fieldset>
                <FieldsetTitle>Appearance</FieldsetTitle>
                <div>
                  <Button size="icon" className="mr-2" onClick={zoomOut}>
                    <SearchMinus className="size-5" />
                  </Button>
                  <Button size="icon" onClick={zoomIn}>
                    <SearchPlus className="size-5" />
                  </Button>
                </div>
              </Fieldset>
            </PopoverContent>
          </Popover>
          <div className="flex items-center gap-1 p-4 whitespace-nowrap tabular-nums">
            <div className="pagination">
              {pageNumber} of {pageCount}
            </div>
            <button
              className="cursor-pointer all-unset"
              aria-label="Previous"
              onClick={() => updatePage("previous")}
              disabled={pageNumber === 1 || pageCount === 1}
            >
              <ArrowLeft className="size-5" />
            </button>
            <button
              className="cursor-pointer all-unset"
              aria-label="Next"
              onClick={() => updatePage("next")}
              disabled={pageNumber === pageCount || pageCount === 1}
            >
              <ArrowRight className="size-5" />
            </button>
          </div>
        </div>

        <WithTooltip
          tip={pageTooltip ? `Page ${pageTooltip.pageNumber}` : null}
          className="z-20 grid"
          tooltipProps={{ style: { left: pageTooltip?.left, pointerEvents: "none" } }}
          onMouseMove={(e) => {
            const width = e.currentTarget.offsetWidth;
            const percent = Math.ceil((100 * e.clientX) / width) / 100;
            const pageNumber = Math.floor(percent * (pageCount - 1)) + 1;
            setPageTooltip({ left: e.clientX, pageNumber });
          }}
          onMouseLeave={() => setPageTooltip(null)}
        >
          <Range
            min={1}
            max={pageCount}
            value={pageNumber}
            onChange={(e) => updatePage(parseInt(e.target.value, 10))}
            progress={((pageNumber - 1) / (pageCount - 1)) * 100}
          />
        </WithTooltip>

        <div className="main relative flex-1 overflow-auto bg-background" role="document">
          <div className="pdf-reader-container">
            <div ref={contentRef} style={{ position: "absolute", height: "100%", width: "100%" }}>
              <div className="pdfViewer"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

// The reading themes a buyer can pick for EPUB content. These style the book's
// own text (inside the epub.js iframe), independently of the app's light/dark
// mode, because readers often want e.g. a sepia book page in a dark app.
const epubThemes = {
  light: { label: "Light", background: "#ffffff", color: "#000000", link: "#146ef5", surface: "#f4f4f0" },
  sepia: { label: "Sepia", background: "#f4ecd8", color: "#5b4636", link: "#754d24", surface: "#e8dcc0" },
  dark: { label: "Dark", background: "#121212", color: "#e6e6e6", link: "#8ab4ff", surface: "#242424" },
} as const;
type EpubThemeName = keyof typeof epubThemes;

const epubFontSizeMin = 70;
const epubFontSizeMax = 200;
const epubFontSizeStep = 10;

const EpubReader = ({
  read_id,
  url,
  url_redirect_id,
  purchase_id,
  product_file_id,
  latest_media_location,
  title,
}: Props) => {
  const [sectionNumber, setSectionNumber] = React.useState(1);
  const [sectionCount, setSectionCount] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(true);
  const [readerError, setReaderError] = React.useState(false);
  const [fontSize, setFontSize] = React.useState(100);
  const [theme, setTheme] = React.useState<EpubThemeName>("light");
  const contentRef = React.useRef<HTMLDivElement>(null);
  const renditionRef = React.useRef<Rendition | null>(null);
  const cleanupReaderRef = React.useRef<() => void>(() => undefined);
  const themeRef = React.useRef<EpubThemeName>("light");
  const linearSectionIndexesRef = React.useRef<number[]>([]);

  const handleReaderError = React.useCallback(() => {
    cleanupReaderRef.current();
    renditionRef.current = null;
    setIsLoading(false);
    setReaderError(true);
  }, []);

  const persistLocation = React.useCallback(
    (progress: number, cfi: string | null) => {
      if (purchase_id) {
        void trackMediaLocationChanged({
          urlRedirectId: url_redirect_id,
          productFileId: product_file_id,
          purchaseId: purchase_id,
          location: progress,
          epubCfi: cfi,
        });
      }
      // CFIs can contain semicolons, which document.cookie treats as attribute
      // separators — URI-encode the value so it round-trips intact.
      document.cookie = `${encodeURIComponent(read_id)}=${encodeURIComponent(
        JSON.stringify({
          location: progress,
          cfi,
          unit: "percentage",
          timestamp: new Date(),
        }),
      )}`;
    },
    [purchase_id, url_redirect_id, product_file_id, read_id],
  );

  const turnPage = React.useCallback(
    (direction: "previous" | "next") => {
      const rendition = renditionRef.current;
      if (!rendition) return;
      void (direction === "next" ? rendition.next() : rendition.prev()).catch(handleReaderError);
    },
    [handleReaderError],
  );

  const goToSection = (newSectionNumber: number) => {
    if (!renditionRef.current || sectionCount === 0) return;
    const clamped = Math.max(1, Math.min(newSectionNumber, sectionCount));
    const spineIndex = linearSectionIndexesRef.current[clamped - 1];
    if (spineIndex == null) return;
    // epub.js accepts a raw 0-based spine index as a display target.
    void displayEpubLocation(renditionRef.current, spineIndex).catch(handleReaderError);
  };

  const updateFontSize = (size: number) => {
    setFontSize(size);
    renditionRef.current?.themes.fontSize(`${size}%`);
  };

  const updateTheme = (name: EpubThemeName) => {
    themeRef.current = name;
    setTheme(name);
    const rendition = renditionRef.current;
    if (!rendition) return;
    rendition.themes.select(name);
    for (const document of getEpubContentDocuments(rendition)) applyEpubThemeToDocument(document, epubThemes[name]);
  };

  React.useEffect(() => {
    let book: Book | null = null;
    let cancelled = false;
    const archiveDownloadController = new AbortController();
    const isCancelled = () => cancelled;
    const destroyBook = () => {
      const openedBook = book;
      book = null;
      openedBook?.destroy();
    };
    const cleanupReader = () => {
      cancelled = true;
      archiveDownloadController.abort();
      renditionRef.current = null;
      destroyBook();
    };
    cleanupReaderRef.current = cleanupReader;
    const handlePageHide = (event: PageTransitionEvent) => {
      if (!event.persisted) {
        archiveDownloadController.abort();
        destroyBook();
      }
    };

    // React runs the returned cleanup for Inertia transitions. A full browser
    // navigation tears down the document instead, so release epub.js resources
    // explicitly while the page's blob URL registry is still reachable.
    window.addEventListener("pagehide", handlePageHide);

    const showBook = async () => {
      const container = contentRef.current;
      if (!container) return;

      try {
        // ProductFile#size is seller-writeable and may be missing, so enforce
        // the compressed limit against the bytes received from storage.
        const archive = await downloadEpubArchive(url, archiveDownloadController.signal);
        if (isCancelled()) return;
        const ePub = (await import("epubjs")).default;
        if (isCancelled()) return;

        // Passing the bounded buffer also avoids a second, unbounded XHR inside
        // epub.js. Its patched archive stream bounds actual inflated bytes.
        const openedBook = ePub();
        book = openedBook;
        await openedBook.open(archive);
        if (isCancelled()) {
          // The request can finish after an Inertia transition and create new
          // archive blob URLs after the first cleanup. Destroy again once the
          // asynchronous open has settled so those late resources are freed.
          openedBook.destroy();
          return;
        }
        // `open()` returns once the package is unpacked, while `opened` waits
        // for archive URLs and rewritten stylesheets. Rendering before that
        // point would make the sanitizer remove valid packaged resources.
        await openedBook.opened;
        if (isCancelled()) {
          openedBook.destroy();
          return;
        }
        // Register after open(), when epub.js has installed its own archive
        // substitution hook. Sanitization must see the resulting blob/data
        // URLs or it cannot distinguish packaged files from network paths.
        openedBook.spine.hooks.serialize.register(sanitizeSerializedEpubSection);

        const spineItems = await openedBook.loaded.spine;
        const totalSections = spineItems.length;
        const linearSectionIndexes: number[] = [];
        openedBook.spine.each((section: { index: number; linear: boolean }) => {
          if (section.linear) linearSectionIndexes.push(section.index);
        });
        if (linearSectionIndexes.length === 0) {
          linearSectionIndexes.push(...Array.from({ length: totalSections }, (_, index) => index));
        }
        const linearSectionCount = linearSectionIndexes.length;
        linearSectionIndexesRef.current = linearSectionIndexes;
        setSectionCount(linearSectionCount);

        const rendition = openedBook.renderTo(container, { width: "100%", height: "100%" });
        renditionRef.current = rendition;
        let isInitialFallbackSuppressed = true;
        let suppressedInitialCfi: string | null = null;
        let lastRelocatedLocation: EpubLocation | null = null;
        let isFallbackSettlementPending = false;
        let pendingFallbackResumeCfi: string | null = null;

        for (const [name, epubTheme] of Object.entries(epubThemes)) {
          rendition.themes.register(name, getEpubThemeRules(name, epubTheme));
        }
        const applyCurrentTheme = () => {
          const currentTheme = themeRef.current;
          rendition.themes.select(currentTheme);
          for (const document of getEpubContentDocuments(rendition)) {
            applyEpubThemeToDocument(document, epubThemes[currentTheme]);
          }
        };
        rendition.on("rendered", applyCurrentTheme);
        applyCurrentTheme();

        // "relocated" fires for page turns, jumps, and resizes. Persist a real
        // book-wide percentage for progress UI and the CFI for exact resume.
        const persistEpubLocation = (location: EpubLocation) => {
          if (cancelled) return;
          lastRelocatedLocation = location;
          const linearSectionIndex = getLinearSectionRank(location.start.index, linearSectionIndexes);
          setSectionNumber(linearSectionIndex + 1);
          if (isFallbackSettlementPending) {
            const fallbackResumeCfi = pendingFallbackResumeCfi;
            isFallbackSettlementPending = false;
            isInitialFallbackSuppressed = false;
            suppressedInitialCfi = null;
            if (fallbackResumeCfi && !location.atEnd) return;
          }
          if (isInitialFallbackSuppressed && suppressedInitialCfi === null) {
            suppressedInitialCfi = location.start.cfi;
            return;
          }
          if (isInitialFallbackSuppressed && location.start.cfi === suppressedInitialCfi) return;
          isInitialFallbackSuppressed = false;
          suppressedInitialCfi = null;
          persistLocation(getEpubProgress(location, linearSectionIndex, linearSectionCount), location.start.cfi);
        };
        rendition.on("relocated", persistEpubLocation);
        // Key events inside the book iframe do not bubble to the window.
        rendition.on("keydown", (e: KeyboardEvent) => {
          if (e.key === "ArrowLeft") turnPage("previous");
          else if (e.key === "ArrowRight") turnPage("next");
        });

        const cookieLocation = getMediaLocationFromCookies(read_id);
        const serverIsFresher =
          latest_media_location &&
          (!cookieLocation.timestamp || new Date(latest_media_location.timestamp) > new Date(cookieLocation.timestamp));
        const resumeLocation = serverIsFresher ? latest_media_location : cookieLocation;
        const completedPercentage = resumeLocation.unit === "percentage" && resumeLocation.location === 100;
        const resumeCfi = completedPercentage ? null : resumeLocation.cfi;
        const legacyLocation = resumeLocation.unit === "page_number" ? resumeLocation.location : null;
        const legacySection =
          !resumeCfi &&
          legacyLocation != null &&
          Number.isInteger(legacyLocation) &&
          legacyLocation >= 1 &&
          legacyLocation <= totalSections
            ? legacyLocation - 1
            : null;
        let fellBackToStart = false;

        try {
          if (resumeCfi) await displayEpubLocation<string>(rendition, resumeCfi);
          else if (legacySection != null) await displayEpubLocation<number>(rendition, legacySection);
          else await displayEpubLocation<string>(rendition);
        } catch (error) {
          if (!resumeCfi && legacySection == null) throw error;
          // A CFI or legacy section may become invalid when a seller replaces
          // an EPUB. Falling back to the first page keeps it readable.
          fellBackToStart = true;
          await displayEpubLocation<string>(rendition);
        }
        rendition.on("displayerror", handleReaderError);
        if (!isCancelled()) setIsLoading(false);

        const settleWithoutContentLocations = () => {
          const fallbackResumeCfi = fellBackToStart ? null : resumeCfi;
          const location = lastRelocatedLocation ?? getCurrentEpubLocation(rendition);
          if (!location) {
            isFallbackSettlementPending = true;
            pendingFallbackResumeCfi = fallbackResumeCfi ?? null;
            return;
          }
          isInitialFallbackSuppressed = false;
          suppressedInitialCfi = null;
          if (!fallbackResumeCfi || location.atEnd) persistEpubLocation(location);
        };
        settleWithoutContentLocations();
      } catch {
        if (!cancelled) {
          cleanupReader();
          setIsLoading(false);
          setReaderError(true);
        }
      }
    };
    void showBook();

    return () => {
      window.removeEventListener("pagehide", handlePageHide);
      linearSectionIndexesRef.current = [];
      cleanupReader();
      if (cleanupReaderRef.current === cleanupReader) cleanupReaderRef.current = () => undefined;
    };
  }, [handleReaderError, latest_media_location, persistLocation, read_id, turnPage, url]);

  React.useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target;
      if (
        e.defaultPrevented ||
        (target instanceof Element &&
          target.closest(
            "a, button, input, select, textarea, [contenteditable='true'], [role='button'], [role='radio'], [role='slider']",
          ))
      )
        return;
      if (e.key === "ArrowLeft") turnPage("previous");
      else if (e.key === "ArrowRight") turnPage("next");
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [turnPage]);

  return (
    <div style={{ display: "contents" }}>
      {readerError ? <ReaderErrorOverlay /> : isLoading ? <ReaderLoadingOverlay /> : null}
      <div role="application" className="scoped-tailwind-preflight flex min-h-screen flex-col">
        <div role="menubar" className="flex text-sm md:text-base">
          <div className="border-r">
            <button aria-label="Back" onClick={() => history.back()} className="cursor-pointer p-4 all-unset">
              <X className="size-5" />
            </button>
          </div>
          <div className="flex flex-1 items-center border-r p-4">
            <h1 className="truncate">{title}</h1>
          </div>
          <Popover>
            <PopoverTrigger aria-label="Appearance" className="border-r p-4">
              <SearchPlus className="size-5" />
            </PopoverTrigger>
            <PopoverContent>
              <Fieldset>
                <FieldsetTitle>Text size</FieldsetTitle>
                <div className="flex items-center gap-2">
                  <Button
                    size="icon"
                    aria-label="Decrease text size"
                    onClick={() => updateFontSize(Math.max(epubFontSizeMin, fontSize - epubFontSizeStep))}
                  >
                    <SearchMinus className="size-5" />
                  </Button>
                  <span className="tabular-nums">{fontSize}%</span>
                  <Button
                    size="icon"
                    aria-label="Increase text size"
                    onClick={() => updateFontSize(Math.min(epubFontSizeMax, fontSize + epubFontSizeStep))}
                  >
                    <SearchPlus className="size-5" />
                  </Button>
                </div>
              </Fieldset>
              <Fieldset>
                <FieldsetTitle>Background</FieldsetTitle>
                <div role="radiogroup" aria-label="Background" className="flex gap-2">
                  {Object.entries(epubThemes).map(([name, { label, background, color }]) => (
                    <button
                      key={name}
                      role="radio"
                      aria-checked={theme === name}
                      aria-label={label}
                      onClick={() => updateTheme(typia.assert<EpubThemeName>(name))}
                      className="cursor-pointer rounded border p-2 all-unset"
                      style={{
                        background,
                        color,
                        borderColor: theme === name ? "var(--accent)" : "var(--border)",
                        borderWidth: theme === name ? 2 : 1,
                        borderStyle: "solid",
                      }}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </Fieldset>
            </PopoverContent>
          </Popover>
          <div className="flex items-center gap-1 p-4 whitespace-nowrap tabular-nums">
            <div className="pagination">
              {sectionNumber} of {sectionCount}
            </div>
            <button
              className="cursor-pointer all-unset"
              aria-label="Previous"
              onClick={() => turnPage("previous")}
              disabled={sectionCount === 0}
            >
              <ArrowLeft className="size-5" />
            </button>
            <button
              className="cursor-pointer all-unset"
              aria-label="Next"
              onClick={() => turnPage("next")}
              disabled={sectionCount === 0}
            >
              <ArrowRight className="size-5" />
            </button>
          </div>
        </div>

        {sectionCount > 1 ? (
          <div className="z-20 grid">
            <Range
              min={1}
              max={sectionCount}
              value={sectionNumber}
              aria-label="Section"
              onChange={(e) => goToSection(parseInt(e.target.value, 10))}
              progress={((sectionNumber - 1) / (sectionCount - 1)) * 100}
            />
          </div>
        ) : null}

        <div
          className="main relative flex-1 overflow-auto"
          role="document"
          style={{ background: epubThemes[theme].background }}
        >
          <div ref={contentRef} style={{ position: "absolute", height: "100%", width: "100%" }} />
        </div>
      </div>
    </div>
  );
};

const ReaderLoadingOverlay = () => (
  <div
    style={{
      position: "absolute",
      height: "100%",
      width: "100%",
      backgroundColor: "var(--body-bg)",
      zIndex: "var(--z-index-tooltip)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--spacer-2)",
      justifyContent: "center",
      alignItems: "center",
      textAlign: "center",
    }}
  >
    <h3>One moment while we prepare your reading experience</h3>
  </div>
);

const ReaderErrorOverlay = () => (
  <div
    role="alert"
    className="scoped-tailwind-preflight absolute flex size-full flex-col items-center justify-center gap-4 bg-background p-6 text-center"
    style={{ zIndex: "var(--z-index-tooltip)" }}
  >
    <h3>We couldn&apos;t open this EPUB</h3>
    <p>You can try loading it again or go back to your files.</p>
    <div className="flex gap-3">
      <Button onClick={() => history.back()}>Back</Button>
      <Button color="primary" onClick={() => location.reload()}>
        Try again
      </Button>
    </div>
  </div>
);

Read.loggedInUserLayout = true;
export default Read;
