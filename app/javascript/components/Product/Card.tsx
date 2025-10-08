import cx from "classnames";
import * as React from "react";

import { CardProduct, Ratings } from "$app/parsers/product";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";

import { Icon } from "$app/components/Icons";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { PriceTag } from "$app/components/Product/PriceTag";
import { Thumbnail } from "$app/components/Product/Thumbnail";

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
  <article className="product-card">
    <figure>
      <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} eager={eager} />
    </figure>
    {product.quantity_remaining != null ? <div className="ribbon">{`${product.quantity_remaining} left`}</div> : null}
    <header>
      <a href={product.url} className="stretched-link">
        <h4 itemProp="name">{product.name}</h4>
      </a>
      {product.seller ? (
        <AuthorByline
          name={product.seller.name}
          profileUrl={product.seller.profile_url}
          avatarUrl={product.seller.avatar_url ?? undefined}
        />
      ) : null}
      {product.ratings?.count ? <Rating ratings={product.ratings} /> : null}
    </header>
    <footer>
      <PriceTag
        url={product.url}
        currencyCode={product.currency_code}
        price={product.price_cents}
        isPayWhatYouWant={product.is_pay_what_you_want}
        isSalesLimited={product.is_sales_limited}
        recurrence={
          product.recurrence ? { id: product.recurrence, duration_in_months: product.duration_in_months } : undefined
        }
        creatorName={product.seller?.name}
      />
      {footerAction}
    </footer>
    {badge}
  </article>
);

export const HorizontalCard = ({ product, big, eager }: { product: CardProduct; big?: boolean; eager?: boolean }) => (
  <article className={cx("product-card horizontal relative", { big })}>
    <figure>
      <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} eager={eager} />
    </figure>
    {product.quantity_remaining != null ? <div className="ribbon">{product.quantity_remaining} left</div> : null}
    <section>
      <header>
        <a href={product.url} className="stretched-link" draggable="false">
          {big ? <h2 itemProp="name">{product.name}</h2> : <h3 itemProp="name">{product.name}</h3>}
        </a>
        <small>{product.description}</small>
        {product.seller ? (
          <AuthorByline
            name={product.seller.name}
            profileUrl={product.seller.profile_url}
            avatarUrl={product.seller.avatar_url ?? undefined}
          />
        ) : null}
      </header>
      <footer>
        <PriceTag
          url={product.url}
          currencyCode={product.currency_code}
          price={product.price_cents}
          isPayWhatYouWant={product.is_pay_what_you_want}
          isSalesLimited={product.is_sales_limited}
          recurrence={
            product.recurrence ? { id: product.recurrence, duration_in_months: product.duration_in_months } : undefined
          }
          creatorName={product.seller?.name}
        />
        {product.ratings?.count ? <Rating ratings={product.ratings} /> : null}
      </footer>
    </section>
  </article>
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
