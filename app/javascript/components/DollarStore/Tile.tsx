import { Star } from "@boxicons/react";
import * as React from "react";

import { getReviews, Review } from "$app/data/product_reviews";
import { CardProduct } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";

import { Thumbnail } from "$app/components/Product/Thumbnail";

type Side = "left" | "right";

type Props = {
  product: CardProduct;
  isAnyActive: boolean;
  isActive: boolean;
  onActivate: (id: string | null) => void;
};

const PANEL_GAP_PX = 12;
const PANEL_WIDTH_PX = 288;
const SIDE_REVIEWS_OFFSET_PX = PANEL_WIDTH_PX + PANEL_GAP_PX * 2;
const MAX_VISIBLE = 4;
const INITIAL_DELAY_MS = 500;
const STAGGER_MS = 400;
const FADE_MS = 200;
const FIRST_CYCLE_DELAY_MS = 10000;
const SUBSEQUENT_CYCLE_DELAY_MS = 5000;

const reviewsCache = new Map<string, Review[]>();

const fetchTopReviews = async (productId: string): Promise<Review[]> => {
  const cached = reviewsCache.get(productId);
  if (cached) return cached;
  const result = await getReviews(productId, 1);
  const top = result.reviews.filter((r) => r.rating >= 4 && r.message && r.message.trim().length > 0);
  reviewsCache.set(productId, top);
  return top;
};

const EMPTY_SLOTS = Array<number | null>(MAX_VISIBLE).fill(null);
const HIDDEN_SLOTS = Array<boolean>(MAX_VISIBLE).fill(false);

export const DollarTile = ({ product, isAnyActive, isActive, onActivate }: Props) => {
  const tileRef = React.useRef<HTMLDivElement>(null);
  const [side, setSide] = React.useState<Side>("right");
  const [reviews, setReviews] = React.useState<Review[]>([]);
  const [slots, setSlots] = React.useState<(number | null)[]>(EMPTY_SLOTS);
  const [visibleSlots, setVisibleSlots] = React.useState<boolean[]>(HIDDEN_SLOTS);
  const timersRef = React.useRef<number[]>([]);

  const handleEnter = () => {
    const rect = tileRef.current?.getBoundingClientRect();
    if (rect) {
      const midpoint = window.innerWidth / 2;
      setSide(rect.left + rect.width / 2 < midpoint ? "right" : "left");
    }
    onActivate(product.id);
  };

  const handleLeave = () => {
    onActivate(null);
  };

  React.useEffect(() => {
    if (!isActive) {
      timersRef.current.forEach((t) => window.clearTimeout(t));
      timersRef.current = [];
      setSlots(EMPTY_SLOTS);
      setVisibleSlots(HIDDEN_SLOTS);
      return;
    }

    let cancelled = false;
    const addTimer = (fn: () => void, ms: number) => {
      const t = window.setTimeout(() => {
        if (!cancelled) fn();
      }, ms);
      timersRef.current.push(t);
    };
    const setSlotContent = (slot: number, reviewIdx: number) =>
      setSlots((prev) => prev.map((s, i) => (i === slot ? reviewIdx : s)));
    const setSlotVisible = (slot: number, value: boolean) =>
      setVisibleSlots((prev) => prev.map((v, i) => (i === slot ? value : v)));

    void fetchTopReviews(product.id)
      .then((top) => {
        if (cancelled || top.length === 0) return;
        setReviews(top);

        const visibleCount = Math.min(top.length, MAX_VISIBLE);
        setSlots(EMPTY_SLOTS.map((_, i) => (i < visibleCount ? i : null)));
        for (let i = 0; i < visibleCount; i++) {
          addTimer(() => setSlotVisible(i, true), INITIAL_DELAY_MS + i * STAGGER_MS);
        }

        if (top.length <= MAX_VISIBLE) return;

        const allVisibleAt = INITIAL_DELAY_MS + (visibleCount - 1) * STAGGER_MS + FADE_MS;
        let cycleSlot = 0;
        let pointer = visibleCount;
        const scheduleCycle = (delay: number) => {
          addTimer(() => {
            const slot = cycleSlot % visibleCount;
            setSlotVisible(slot, false);
            addTimer(() => {
              const nextIdx = pointer % top.length;
              pointer += 1;
              setSlotContent(slot, nextIdx);
              setSlotVisible(slot, true);
            }, FADE_MS);
            cycleSlot += 1;
            scheduleCycle(SUBSEQUENT_CYCLE_DELAY_MS);
          }, delay);
        };
        addTimer(() => scheduleCycle(FIRST_CYCLE_DELAY_MS), allVisibleAt);
      })
      .catch(() => {});

    return () => {
      cancelled = true;
      timersRef.current.forEach((t) => window.clearTimeout(t));
      timersRef.current = [];
    };
  }, [isActive, product.id]);

  const formattedPrice =
    product.price_cents === 0
      ? "Free"
      : formatPriceCentsWithCurrencySymbol(product.currency_code, product.price_cents, { symbolFormat: "long" });

  const ratingsCount = product.ratings?.count ?? 0;

  const renderReviewCard = (slotIdx: number) => {
    const reviewIdx = slots[slotIdx];
    const review = reviewIdx != null ? reviews[reviewIdx] : null;
    if (!review) return null;
    return (
      <div
        key={slotIdx}
        className={classNames(
          "flex flex-col gap-3 rounded-lg border border-black bg-white p-5 text-black shadow-xl transition-opacity ease-out",
          visibleSlots[slotIdx] ? "opacity-100" : "opacity-0",
        )}
        style={{ transitionDuration: `${FADE_MS}ms` }}
      >
        <div className="flex items-center gap-1">
          {Array.from({ length: review.rating }).map((_, s) => (
            <Star key={s} pack="filled" className="size-4" />
          ))}
        </div>
        <p className="line-clamp-4 text-sm leading-snug text-black">{review.message}</p>
        <div className="flex items-center gap-2">
          <img src={review.rater.avatar_url} alt="" className="size-6 rounded-full" />
          <span className="truncate text-sm text-dark-gray">{review.rater.name}</span>
        </div>
      </div>
    );
  };

  return (
    <div
      ref={tileRef}
      data-active={isActive ? "true" : undefined}
      onMouseEnter={handleEnter}
      onMouseLeave={handleLeave}
      onFocus={handleEnter}
      onBlur={handleLeave}
      className={classNames(
        "group relative transition-all duration-200 ease-out",
        isAnyActive && !isActive && "opacity-40 blur-[2px]",
        isActive && "z-20 scale-[1.02]",
      )}
    >
      <a
        href={product.url}
        className="block aspect-square overflow-hidden rounded-md border border-black/10 bg-white shadow-sm transition-shadow group-hover:shadow-md [&_img]:size-full [&_img]:object-cover"
      >
        <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
      </a>

      {isActive ? (
        <>
          <div
            className={classNames(
              "pointer-events-auto absolute top-0 z-30 flex w-72 max-w-none flex-col gap-3",
              side === "right" ? "left-full ml-3" : "right-full mr-3",
            )}
          >
            <div className="flex flex-col gap-3 rounded-lg border border-black bg-white p-5 text-black shadow-xl">
              <div className="flex flex-col gap-1">
                <h3 className="text-lg leading-tight">{product.name}</h3>
                {product.seller ? <p className="text-sm text-dark-gray">by {product.seller.name}</p> : null}
              </div>
              {product.description ? (
                <p className="line-clamp-4 text-sm leading-snug text-dark-gray">{product.description}</p>
              ) : null}
              <div className="flex items-center justify-between gap-3 pt-1">
                <span className="text-xl">{formattedPrice}</span>
                {ratingsCount > 0 && product.ratings ? (
                  <div className="flex shrink-0 items-center gap-1 text-xl" aria-label="Rating">
                    <Star pack="filled" className="size-5" />
                    <span>{product.ratings.average.toFixed(1)}</span>
                    <span className="text-dark-gray">({formatOrderOfMagnitude(product.ratings.count, 1)})</span>
                  </div>
                ) : null}
              </div>
            </div>

            <div aria-hidden className="hidden flex-col gap-3 lg:flex">
              {renderReviewCard(2)}
              {renderReviewCard(3)}
            </div>
          </div>

          <div
            aria-hidden
            className={classNames(
              "pointer-events-none absolute top-0 z-30 hidden w-72 max-w-none flex-col gap-3 lg:flex",
              side === "right" ? "left-full" : "right-full",
            )}
            style={
              side === "right"
                ? { marginLeft: SIDE_REVIEWS_OFFSET_PX }
                : { marginRight: SIDE_REVIEWS_OFFSET_PX }
            }
          >
            {renderReviewCard(0)}
            {renderReviewCard(1)}
          </div>
        </>
      ) : null}
    </div>
  );
};
