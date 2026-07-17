import { ArrowLeft, ArrowRight, SearchMinus, SearchPlus, X } from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import type { Rendition, Location as EpubLocation } from "epubjs";
import type { PDFSinglePageViewer } from "pdfjs-dist/legacy/web/pdf_viewer.mjs";
import * as React from "react";
import typia from "typia";

import { trackMediaLocationChanged } from "$app/data/media_location";

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
  latest_media_location: { location: number; timestamp: string } | null;
  title: string;
  file_type: "pdf" | "epub";
};

// The reading position we persist in a cookie so an anonymous (or same-browser)
// reader can pick up where they left off. For PDFs `location` is a page number;
// for EPUBs it is a 1-based spine section number and `cfi` additionally stores
// the exact position within that section (an EPUB Canonical Fragment Identifier).
type StoredMediaLocation = { timestamp?: string | null; location?: number | null; cfi?: string | null };

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
      const latestMediaLocationFromCookies = getMediaLocationFromCookies(read_id);

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
  light: { label: "Light", background: "#ffffff", color: "#000000" },
  sepia: { label: "Sepia", background: "#f4ecd8", color: "#5b4636" },
  dark: { label: "Dark", background: "#121212", color: "#e6e6e6" },
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
  // EPUBs don't have fixed pages; the closest stable notion of "where am I" that
  // fits the existing media_locations schema (an integer `location` column) is the
  // 1-based spine section number — the same unit the backend already stores as
  // `pagelength` when it analyzes an EPUB upload. The exact position within a
  // section (a CFI string) is too granular for that column, so we keep it in the
  // same cookie the PDF reader uses and prefer it when resuming in this browser.
  const [sectionNumber, setSectionNumber] = React.useState(1);
  const [sectionCount, setSectionCount] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(true);
  const [fontSize, setFontSize] = React.useState(100);
  const [theme, setTheme] = React.useState<EpubThemeName>("light");
  const contentRef = React.useRef<HTMLDivElement>(null);
  const renditionRef = React.useRef<Rendition | null>(null);

  const persistLocation = React.useCallback(
    (newSectionNumber: number, cfi: string | null) => {
      setSectionNumber(newSectionNumber);
      if (purchase_id) {
        void trackMediaLocationChanged({
          urlRedirectId: url_redirect_id,
          productFileId: product_file_id,
          purchaseId: purchase_id,
          location: newSectionNumber,
        });
      }
      // CFIs can contain semicolons, which document.cookie treats as attribute
      // separators — URI-encode the value so it round-trips intact.
      document.cookie = `${encodeURIComponent(read_id)}=${encodeURIComponent(
        JSON.stringify({
          location: newSectionNumber,
          cfi,
          timestamp: new Date(),
        }),
      )}`;
    },
    [purchase_id, url_redirect_id, product_file_id, read_id],
  );

  const turnPage = (direction: "previous" | "next") => {
    if (!renditionRef.current) return;
    void (direction === "next" ? renditionRef.current.next() : renditionRef.current.prev());
  };

  const goToSection = (newSectionNumber: number) => {
    if (!renditionRef.current || sectionCount === 0) return;
    const clamped = Math.max(1, Math.min(newSectionNumber, sectionCount));
    // epub.js accepts a 0-based spine index as a display target.
    void renditionRef.current.display(clamped - 1);
  };

  const updateFontSize = (size: number) => {
    setFontSize(size);
    renditionRef.current?.themes.fontSize(`${size}%`);
  };

  const updateTheme = (name: EpubThemeName) => {
    setTheme(name);
    renditionRef.current?.themes.select(name);
  };

  useRunOnce(() => {
    const showBook = async () => {
      if (!contentRef.current) return;

      const ePub = (await import("epubjs")).default;
      const book = ePub(url);
      const rendition = book.renderTo(contentRef.current, { width: "100%", height: "100%" });
      renditionRef.current = rendition;

      for (const [name, { background, color }] of Object.entries(epubThemes)) {
        rendition.themes.register(name, { body: { background, color } });
      }
      rendition.themes.select("light");

      // "relocated" fires whenever the visible position changes (page turn,
      // jump, resize). It is the equivalent of the PDF reader's page updates.
      rendition.on("relocated", (location: EpubLocation) => {
        persistLocation(location.start.index + 1, location.start.cfi);
      });
      // Key events inside the book's iframe don't bubble to the window, so
      // epub.js re-emits them and we handle arrow keys here as well.
      rendition.on("keydown", (e: KeyboardEvent) => {
        if (e.key === "ArrowLeft") turnPage("previous");
        else if (e.key === "ArrowRight") turnPage("next");
      });

      const spineItems = await book.loaded.spine;
      const totalSections = spineItems.length;
      setSectionCount(totalSections);

      // Resume from wherever the buyer last stopped reading: the cookie (with
      // its precise CFI) wins if it is fresher than the server-side record,
      // mirroring how the PDF reader resolves page numbers.
      const cookieLocation = getMediaLocationFromCookies(read_id);
      const serverIsFresher =
        latest_media_location &&
        (!cookieLocation.timestamp || new Date(latest_media_location.timestamp) > new Date(cookieLocation.timestamp));
      if (serverIsFresher) {
        const location = latest_media_location.location;
        await rendition.display(location > totalSections ? 0 : location - 1);
      } else if (cookieLocation.cfi) {
        await rendition.display(cookieLocation.cfi);
      } else if (cookieLocation.location != null) {
        const location = cookieLocation.location;
        await rendition.display(location > totalSections ? 0 : location - 1);
      } else {
        await rendition.display();
      }
      setIsLoading(false);
    };
    void showBook();
  });

  React.useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft") turnPage("previous");
      else if (e.key === "ArrowRight") turnPage("next");
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, []);

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

Read.loggedInUserLayout = true;
export default Read;
