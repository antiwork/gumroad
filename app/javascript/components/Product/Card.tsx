import * as React from "react";

import { CardProduct, Ratings } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";

import { Icon } from "$app/components/Icons";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { PriceTag } from "$app/components/Product/PriceTag";
import { Ribbon } from "$app/components/Product/Ribbon";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { ProductCard, ProductCardFigure, ProductCardHeader, ProductCardFooter } from "$app/components/ui/ProductCard";

export const Card = ({
  product,
  badge,
  footerAction,
  eager,
}: {
  product: CardProduct;
  badge?: React.ReactNode;
  footerAction?: React.ReactNode;
  eager?: boolean | undefined;
}) => (
  <ProductCard>
    <ProductCardFigure>
      <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} eager={eager} />
    </ProductCardFigure>
    {product.quantity_remaining != null ? <Ribbon>{product.quantity_remaining} left</Ribbon> : null}
    <ProductCardHeader>
      <a href={product.url} className="stretched-link">
        <h4 itemProp="name" className="line-clamp-4 lg:text-xl">
          {product.name}
        </h4>
      </a>
      {product.seller ? (
        <AuthorByline
          name={product.seller.name}
          profileUrl={product.seller.profile_url}
          avatarUrl={product.seller.avatar_url ?? undefined}
        />
      ) : null}
      {product.ratings?.count ? <Rating ratings={product.ratings} /> : null}
    </ProductCardHeader>
    <ProductCardFooter>
      <div className="flex-1 p-4">
        <PriceTag
          url={product.url}
          currencyCode={product.currency_code}
          price={product.price_cents}
          oldPrice={product.original_price_cents ?? undefined}
          isPayWhatYouWant={product.is_pay_what_you_want}
          isSalesLimited={product.is_sales_limited}
          recurrence={
            product.recurrence ? { id: product.recurrence, duration_in_months: product.duration_in_months } : undefined
          }
          creatorName={product.seller?.name}
        />
      </div>
      {footerAction}
    </ProductCardFooter>
    {badge}
  </ProductCard>
);

export const HorizontalCard = ({ product, big, eager }: { product: CardProduct; big?: boolean; eager?: boolean }) => (
  <ProductCard className="lg:flex-row">
    <ProductCardFigure className="lg:h-full lg:rounded-l lg:rounded-tr-none lg:border-r lg:border-b-0 [&_img]:lg:h-0 [&_img]:lg:min-h-full lg:[&_img]:w-auto">
      <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} eager={eager} />
    </ProductCardFigure>
    {product.quantity_remaining !== null ? <Ribbon>{product.quantity_remaining} left</Ribbon> : null}
    <section className="flex flex-1 flex-col lg:gap-8 lg:px-6 lg:py-4">
      <ProductCardHeader className="lg:border-b-0 lg:p-0">
        <a href={product.url} className="stretched-link" draggable="false">
          {big ? (
            <h2 itemProp="name" className="line-clamp-3 gap-3">
              {product.name}
            </h2>
          ) : (
            <h3 itemProp="name" className="truncate">
              {product.name}
            </h3>
          )}
        </a>
        <small className={classNames("hidden truncate text-muted lg:block", big && "lg:line-clamp-4")}>
          {product.description}
        </small>
        {product.seller ? (
          <AuthorByline
            name={product.seller.name}
            profileUrl={product.seller.profile_url}
            avatarUrl={product.seller.avatar_url ?? undefined}
          />
        ) : null}
      </ProductCardHeader>
      <ProductCardFooter className="items-center lg:divide-x-0">
        <div className="flex-1 p-4 lg:p-0">
          <PriceTag
            url={product.url}
            currencyCode={product.currency_code}
            price={product.price_cents}
            oldPrice={product.original_price_cents ?? undefined}
            isPayWhatYouWant={product.is_pay_what_you_want}
            isSalesLimited={product.is_sales_limited}
            recurrence={
              product.recurrence
                ? { id: product.recurrence, duration_in_months: product.duration_in_months }
                : undefined
            }
            creatorName={product.seller?.name}
          />
        </div>
        {product.ratings?.count ? (
          <div className="p-4 lg:p-0">
            <Rating ratings={product.ratings} />
          </div>
        ) : null}
      </ProductCardFooter>
    </section>
  </ProductCard>
);

const Rating = ({ ratings, style }: { ratings: Ratings; style?: React.CSSProperties }) => (
  <div className="flex shrink-0 items-center gap-1" aria-label="Rating" style={style}>
    <Icon name="solid-star" />
    <span className="rating-average">{ratings.average.toFixed(1)}</span>
    <span title={`${ratings.average} ${ratings.average === 1 ? "rating" : "ratings"}`}>
      {`(${formatOrderOfMagnitude(ratings.count, 1)})`}
    </span>
  </div>
);
