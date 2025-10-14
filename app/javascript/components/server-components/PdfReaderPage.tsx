import type { PDFSinglePageViewer } from "pdfjs-dist/legacy/web/pdf_viewer.mjs";
import * as React from "react";
import { cast, createCast, is } from "ts-safe-cast";

import { trackMediaLocationChanged } from "$app/data/media_location";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { useRunOnce } from "$app/components/useRunOnce";

const zoomLevelMin = 0.1;
const zoomLevelMax = 5.0;

export const PdfReaderPage = ({
  read_id,
  url,
  url_redirect_id,
  purchase_id,
  product_file_id,
  latest_media_location,
  title,
}: {
  read_id: string;
  url: string;
  url_redirect_id: string;
  purchase_id: string | null;
  product_file_id: string;
  latest_media_location: { location: number; timestamp: string } | null;
  title: string;
}) => {
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
      document.cookie = `${encodeURIComponent(read_id)}=${JSON.stringify({
        location: newPageNumber,
        timestamp: new Date(),
      })}`;
    },
    [pageNumber, pageCount],
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
    const getLatestMediaLocationFromCookies = () => {
      const cookieValue = document.cookie
        .split("; ")
        .find((row) => row.startsWith(encodeURIComponent(read_id)))
        ?.split("=")[1];
      if (cookieValue) {
        const json: unknown = JSON.parse(cookieValue);
        if (is<{ timestamp?: string | null; location?: number | null }>(json)) return json;
      }
      return {};
    };

    const resumeFromLastLocation = (pageCount: number) => {
      const latestMediaLocationFromCookies = getLatestMediaLocationFromCookies();

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
      pdfjs.GlobalWorkerOptions.workerSrc = cast<{ default: string }>(
        // @ts-expect-error pdfjs-dist worker is not typed
        await import("pdfjs-dist/legacy/build/pdf.worker.mjs?resource"),
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
      {isLoading ? (
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
      ) : null}
      <div role="application" className="scoped-tailwind-preflight flex h-full flex-col">
        <div role="menubar" className="flex text-sm md:text-base">
          <div className="border-r">
            <button aria-label="Back" onClick={() => history.back()} className="p-4">
              <Icon name="x" />
            </button>
          </div>
          <div className="flex flex-1 items-center border-r p-4">
            <h1 className="truncate">{title}</h1>
          </div>
          <Popover
            aria-label="Appearance"
            trigger={
              <div className="border-r p-4">
                <Icon name="zoom-in" />
              </div>
            }
          >
            <fieldset>
              <legend>Appearance</legend>
              <div>
                <Button className="mr-2" onClick={zoomOut}>
                  <Icon name="zoom-out" />
                </Button>
                <Button onClick={zoomIn}>
                  <Icon name="zoom-in" />
                </Button>
              </div>
            </fieldset>
          </Popover>
          <div className="flex items-center gap-1 p-4 whitespace-nowrap tabular-nums">
            <div className="pagination">
              {pageNumber} of {pageCount}
            </div>
            <button
              className="icon icon-arrow-left previous"
              aria-label="Previous"
              onClick={() => updatePage("previous")}
              disabled={pageNumber === 1 || pageCount === 1}
            />
            <button
              className="icon icon-arrow-right next"
              aria-label="Next"
              onClick={() => updatePage("next")}
              disabled={pageNumber === pageCount || pageCount === 1}
            />
          </div>
        </div>

        <div
          className="has-tooltip"
          style={{ display: "flex", zIndex: "var(--z-index-menubar)" }}
          onMouseMove={(e) => {
            const width = e.currentTarget.offsetWidth;
            const percent = Math.ceil((100 * e.clientX) / width) / 100;
            const pageNumber = Math.floor(percent * (pageCount - 1)) + 1;
            setPageTooltip({ left: e.clientX, pageNumber });
          }}
          onMouseOut={() => setPageTooltip(null)}
        >
          <input
            type="range"
            min={1}
            max={pageCount}
            value={pageNumber}
            onChange={(e) => updatePage(parseInt(e.target.value, 10))}
            style={{
              flexGrow: 1,
              "--progress": `${((pageNumber - 1) / (pageCount - 1)) * 100}%`,
            }}
          />
          <div
            className="js-page-slider-popover"
            role="tooltip"
            style={{ left: pageTooltip?.left, display: pageTooltip ? "block" : "none" }}
          >
            Page {pageTooltip?.pageNumber}
          </div>
        </div>

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

export default register({ component: PdfReaderPage, propParser: createCast() });
