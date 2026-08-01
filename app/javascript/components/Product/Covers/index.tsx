import { ArrowLeft, ArrowRight } from "@boxicons/react";
import * as React from "react";

import { AssetPreview } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { MAX_PORTRAIT_FRAME_HEIGHT } from "$app/utils/videoFrame";

import { useElementDimensions } from "$app/components/useElementDimensions";
import { useOnChange } from "$app/components/useOnChange";
import { useScrollableCarousel } from "$app/components/useScrollableCarousel";

import { Embed } from "./Embed";
import { Image } from "./Image";
import { Video } from "./Video";

export const DEFAULT_IMAGE_WIDTH = 1005;

export const Covers = ({
  covers,
  activeCoverId,
  setActiveCoverId,
  closeButton,
  className,
  isThumbnail,
}: {
  covers: AssetPreview[];
  activeCoverId: string | null;
  setActiveCoverId: (id: string | null) => void;
  closeButton?: React.ReactNode;
  className?: string;
  isThumbnail?: boolean;
}) => {
  useOnChange(() => {
    if (!covers.some((cover) => cover.id === activeCoverId)) setActiveCoverId(covers[0]?.id ?? null);
  }, [covers]);

  let activeCoverIndex = covers.findIndex((cover) => cover.id === activeCoverId);
  if (activeCoverIndex === -1) activeCoverIndex = 0;
  const activeCover = covers[activeCoverIndex];
  // Shape the cover frame to the cover the buyer is actually looking at, and stop it
  // growing taller than the window.
  //
  // The ratio used to come from `covers[0]` unconditionally, so a product whose first
  // cover was landscape squeezed every later cover into 16:9 — a phone-filmed 9:16
  // video showed as a thin strip between wide bars. Following the active cover fixes
  // that, but alone it creates the opposite problem: a 9:16 frame at the full width of
  // the product column derives a height about 1.8x that width, taller than a laptop
  // window, pushing the title and Buy button below the fold. `maxHeight` caps that the
  // same way the buyer content page was capped in #6367; the frame keeps the column's
  // full width and the video letterboxes horizontally inside it (see CoverItem).
  //
  // The cap has to be a max-HEIGHT rather than a narrower frame: the carousel decides
  // which cover is active by comparing scroll offsets against each panel's width, so a
  // frame that changed width with the active cover would move the panels out from under
  // that calculation and bounce a two-cover carousel back to the first cover.
  //
  // Only portrait gets the cap, and the exclusion is load-bearing: because the frame
  // cannot narrow, a cap shorter than the ratio makes `object-contain` shrink the cover
  // in BOTH axes, so capping a shape that does not need it buys empty side bars and
  // nothing else. Only portrait needs it — a cover no taller than it is wide derives a
  // frame at most the column's width, which is not the runaway a 9:16 frame (~1.8x its
  // width) is.
  //
  // Covers with no recorded dimensions still get no ratio at all and fall back to the
  // CSS box exactly as before.
  // See https://github.com/antiwork/gumroad-private/issues/1437
  const frameStyle =
    isThumbnail || !activeCover?.native_width || !activeCover.native_height
      ? undefined
      : {
          // Width is pinned so the frame always spans the product column: with only a
          // ratio and a max-height, a portrait ratio makes the browser DERIVE a
          // narrower width, which moves the carousel panels and breaks the scroll
          // position the active-cover calculation reads.
          width: "100%",
          aspectRatio: `${activeCover.native_width} / ${activeCover.native_height}`,
          ...(activeCover.native_height > activeCover.native_width ? { maxHeight: MAX_PORTRAIT_FRAME_HEIGHT } : {}),
        };
  const prevCover = covers[activeCoverIndex - 1];
  const nextCover = covers[activeCoverIndex + 1];
  // Whether the frame is shaped to the cover also decides the backdrop. Once the frame
  // has the cover's own ratio, the cover fills it exactly UNLESS the height cap bites,
  // in which case the cover narrows and whatever is behind it becomes visible for the
  // first time. The decorative tiled artwork is meant for products with no cover at
  // all, and tiling it either side of a cover reads as a rendering glitch, so a shaped
  // frame uses the plain page background instead. Keyed on "the frame is shaped" rather
  // than "the cap bit" because behind a cover that does fill its frame the backdrop is
  // invisible either way, so the broader condition is a no-op there and stays correct if
  // the cap's shape test changes.
  const frameIsShaped = frameStyle !== undefined;

  const { itemsRef, handleScroll } = useScrollableCarousel(activeCoverIndex, (index) =>
    setActiveCoverId(covers[index]?.id ?? null),
  );

  return (
    <figure
      className={classNames(
        "group relative col-span-full overflow-hidden rounded-t border-b border-border bg-cover",
        frameIsShaped ? "bg-background" : "bg-(image:--product-cover-placeholder)",
        className,
      )}
      aria-label="Product preview"
    >
      {closeButton}
      {prevCover ? <PreviewArrow direction="previous" onClick={() => setActiveCoverId(prevCover.id)} /> : null}
      {nextCover ? <PreviewArrow direction="next" onClick={() => setActiveCoverId(nextCover.id)} /> : null}
      <div
        className="flex h-full snap-x snap-mandatory items-center overflow-x-scroll overflow-y-hidden [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
        ref={itemsRef}
        style={frameStyle}
        onScroll={handleScroll}
      >
        {covers.map((cover) => (
          <CoverItem cover={cover} frameIsShaped={frameIsShaped} key={cover.id} />
        ))}
      </div>
      {covers.length > 1 && activeCover?.type !== "oembed" && activeCover?.type !== "video" ? (
        <div
          role="tablist"
          aria-label="Select a cover"
          className="absolute bottom-0 flex w-full flex-wrap justify-center gap-2 p-3"
        >
          {covers.map((cover, i) => (
            <div
              key={i}
              role="tab"
              aria-label={`Show cover ${i + 1}`}
              aria-selected={i === activeCoverIndex}
              aria-controls={cover.id}
              onClick={(e) => {
                e.preventDefault();
                setActiveCoverId(cover.id);
              }}
              className={classNames(
                "block rounded-full border border-current bg-background p-2",
                i === activeCoverIndex && "bg-current",
              )}
            />
          ))}
        </div>
      ) : null}
    </figure>
  );
};

const PreviewArrow = ({ direction, onClick }: { direction: "previous" | "next"; onClick: () => void }) => {
  const positionClass = direction === "previous" ? "left-0" : "right-0";

  return (
    <button
      className={classNames(
        "absolute top-1/2 z-1 mx-3 h-8 w-8 -translate-y-1/2 items-center justify-center all-unset",
        "rounded-full border border-border bg-background",
        "hidden group-hover:flex",
        positionClass,
      )}
      onClick={(e) => {
        e.preventDefault();
        onClick();
      }}
      aria-label={direction === "previous" ? "Show previous cover" : "Show next cover"}
    >
      {direction === "previous" ? <ArrowLeft className="size-5" /> : <ArrowRight className="size-5" />}
    </button>
  );
};

const CoverItem = ({ cover, frameIsShaped }: { cover: AssetPreview; frameIsShaped: boolean }) => {
  const containerRef = React.useRef<HTMLDivElement>(null);
  const dimensions = useElementDimensions(containerRef);
  const width = dimensions?.width;

  let coverComponent: React.ReactNode;
  if (cover.type === "unsplash") {
    coverComponent = <img src={cover.url} />;
  } else if (
    width &&
    cover.width !== null &&
    cover.height !== null &&
    cover.native_width !== null &&
    cover.native_height !== null
  ) {
    const ratio = width / cover.native_width;
    const dimensions =
      ratio >= 1
        ? {
            width: cover.width,
            height: cover.height,
          }
        : {
            width: cover.native_width * ratio,
            height: cover.native_height * ratio,
          };
    if (cover.type === "image") {
      coverComponent = <Image cover={cover} dimensions={dimensions} frameIsShaped={frameIsShaped} />;
    } else if (cover.type === "oembed") {
      coverComponent = <Embed cover={cover} dimensions={dimensions} frameIsShaped={frameIsShaped} />;
    } else {
      coverComponent = <Video cover={cover} dimensions={dimensions} frameIsShaped={frameIsShaped} />;
    }
  }

  return (
    <div
      key={cover.id}
      ref={containerRef}
      role="tabpanel"
      id={cover.id}
      // h-full lets a cover fill the (possibly height-capped) frame instead of
      // overflowing it: a portrait cover's natural height is far greater than the cap,
      // and without this the cover would spill past the bottom of the figure. It is
      // only applied when the frame has a definite height to fill; in an unshaped frame
      // it would resolve to auto and collapse the panel.
      className={classNames(
        "mt-0! flex min-h-[1px] flex-[1_0_100%] snap-start items-center justify-center border-0! p-0!",
        frameIsShaped && "h-full",
      )}
    >
      {coverComponent}
    </div>
  );
};
