import cx from "classnames";
import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

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
  const aspectRatio =
    !isThumbnail && covers[0]?.native_height && covers[0]?.native_width
      ? covers[0].native_width / covers[0].native_height
      : undefined;
  const prevCover = covers[activeCoverIndex - 1];
  const nextCover = covers[activeCoverIndex + 1];

  const { itemsRef, handleScroll } = useScrollableCarousel(activeCoverIndex, (index) =>
    setActiveCoverId(covers[index]?.id ?? null),
  );

  return (
    <figure className={cx("carousel", className)} aria-label="Product preview">
      {closeButton}
      {prevCover ? <PreviewArrow direction="previous" onClick={() => setActiveCoverId(prevCover.id)} /> : null}
      {nextCover ? <PreviewArrow direction="next" onClick={() => setActiveCoverId(nextCover.id)} /> : null}
      <div
        className="items"
        ref={itemsRef}
        style={{
          aspectRatio,
        }}
        onScroll={handleScroll}
      >
        {covers.map((cover) => (
          <CoverItem cover={cover} key={cover.id} />
        ))}
      </div>
      {covers.length > 1 && activeCover?.type !== "oembed" && activeCover?.type !== "video" ? (
        <div role="tablist" aria-label="Select a cover">
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
            />
          ))}
        </div>
      ) : null}
    </figure>
  );
};

const PreviewArrow = ({ direction, onClick }: { direction: "previous" | "next"; onClick: () => void }) => (
  <button
    className={cx("arrow", direction)}
    onClick={(e) => {
      e.preventDefault();
      onClick();
    }}
    aria-label={direction === "previous" ? "Show previous cover" : "Show next cover"}
  />
);

const CoverItem = ({ cover }: { cover: AssetPreview }) => {
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
      coverComponent = <Image cover={cover} dimensions={dimensions} />;
    } else if (cover.type === "oembed") {
      coverComponent = <Embed cover={cover} dimensions={dimensions} />;
    } else {
      coverComponent = <Video cover={cover} dimensions={dimensions} />;
    }
  }

  return (
    <div key={cover.id} ref={containerRef} role="tabpanel" id={cover.id}>
      {coverComponent}
    </div>
  );
};
