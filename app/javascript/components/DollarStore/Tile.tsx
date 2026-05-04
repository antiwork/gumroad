import * as React from "react";

import { CardProduct } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Thumbnail } from "$app/components/Product/Thumbnail";

type Side = "left" | "right";

type Props = {
  product: CardProduct;
  isAnyActive: boolean;
  isActive: boolean;
  onActivate: (id: string | null) => void;
};

const buildAddToCartUrl = (productUrl: string) => {
  const url = new URL(productUrl);
  url.searchParams.set("wanted", "true");
  return url.toString();
};

export const DollarTile = ({ product, isAnyActive, isActive, onActivate }: Props) => {
  const tileRef = React.useRef<HTMLDivElement>(null);
  const [side, setSide] = React.useState<Side>("right");

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

  const formattedPrice =
    product.price_cents === 0
      ? "Free"
      : formatPriceCentsWithCurrencySymbol(product.currency_code, product.price_cents, { symbolFormat: "long" });

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
        <div
          className={classNames(
            "pointer-events-auto absolute top-0 z-30 w-72 rounded-lg border border-black bg-white p-5 text-black shadow-xl",
            side === "right" ? "left-full ml-3" : "right-full mr-3",
          )}
        >
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <h3 className="text-lg leading-tight">{product.name}</h3>
              {product.seller ? <p className="text-sm text-dark-gray">by {product.seller.name}</p> : null}
            </div>
            {product.description ? (
              <p className="line-clamp-4 text-sm leading-snug text-dark-gray">{product.description}</p>
            ) : null}
            <div className="flex items-center justify-between gap-3 pt-1">
              <span className="text-xl">{formattedPrice}</span>
              <a
                href={buildAddToCartUrl(product.url)}
                className="rounded-sm border border-black bg-pink px-3 py-2 text-sm whitespace-nowrap text-black no-underline transition-transform hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-[2px_2px_0_0_rgba(0,0,0,1)]"
              >
                Add to cart
              </a>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
};
