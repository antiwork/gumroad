import { FastAverageColor } from "fast-average-color";
import * as React from "react";
import { cast } from "ts-safe-cast";

import useLazyLoadingProps from "$app/hooks/useLazyLoadingProps";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";
import { getCssVariable } from "$app/utils/styles";

import { Icon } from "$app/components/Icons";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { useFollowWishlist } from "$app/components/Wishlist/FollowButton";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

export type CardWishlist = {
  id: string;
  url: string;
  name: string;
  description: string | null;
  seller: { id: string; name: string; profile_url: string; avatar_url: string };
  thumbnails: { url: string | null; native_type: string }[];
  product_count: number;
  follower_count: number;
  following: boolean;
  can_follow: boolean;
};

type CardProps = {
  wishlist: CardWishlist;
  hideSeller?: boolean;
  eager?: boolean;
};

export const Card = ({ wishlist, hideSeller, eager }: CardProps) => {
  const { isFollowing, isLoading, toggleFollowing } = useFollowWishlist({
    wishlistId: wishlist.id,
    wishlistName: wishlist.name,
    initialValue: wishlist.following,
  });
  const lazyLoadingProps = useLazyLoadingProps({ eager });

  const thumbnailUrl = wishlist.thumbnails.find((thumbnail) => thumbnail.url)?.url;
  const [backgroundColor, setBackgroundColor] = React.useState<string>(thumbnailUrl ? "transparent" : "var(--pink)");
  React.useEffect(() => {
    const updateBackgroundColor = async () => {
      if (!thumbnailUrl) return;
      const validColors = ["--pink", "--purple", "--green", "--orange", "--red", "--yellow"].map((color) =>
        getCssVariable(color),
      );

      const {
        value: [r, g, b],
      } = await new FastAverageColor().getColorAsync(thumbnailUrl);

      const distances = validColors.map((hex) => {
        const [vr, vg, vb] = cast<[number, number, number]>(
          hex
            .slice(1)
            .match(/.{2}/gu)
            ?.map((x) => parseInt(x, 16)),
        );
        return Math.sqrt((r - vr) ** 2 + (g - vg) ** 2 + (b - vb) ** 2);
      });
      const closestValidColor = validColors[distances.indexOf(Math.min(...distances))];
      if (closestValidColor) {
        setBackgroundColor(closestValidColor);
      }
    };
    void updateBackgroundColor();
  }, [thumbnailUrl]);

  return (
    <article className="product-card horizontal">
      <figure className="thumbnails" style={{ backgroundColor }}>
        {wishlist.thumbnails.map(({ url, native_type }, index) => (
          <img
            key={index}
            src={url ?? cast(nativeTypeThumbnails(`./${native_type}.svg`))}
            role="presentation"
            crossOrigin="anonymous"
            {...lazyLoadingProps}
          />
        ))}
        {wishlist.thumbnails.length === 0 ? <img role="presentation" /> : null}
      </figure>
      <section>
        <header>
          <a className="stretched-link" href={wishlist.url}>
            <h3>{wishlist.name}</h3>
          </a>
          {wishlist.description ? <small>{wishlist.description}</small> : null}
          {hideSeller ? null : (
            <AuthorByline
              name={wishlist.seller.name}
              profileUrl={wishlist.seller.profile_url}
              avatarUrl={wishlist.seller.avatar_url}
            />
          )}
        </header>
        <footer>
          <div className="metrics">
            <span className="detail">
              <span className="icon icon-file-text-fill" /> {wishlist.product_count}{" "}
              {wishlist.product_count === 1 ? "product" : "products"}
            </span>
            <span>
              <span className="icon icon-bookmark-fill" /> {formatOrderOfMagnitude(wishlist.follower_count, 1)}{" "}
              {wishlist.follower_count === 1 ? "follower" : "followers"}
            </span>
          </div>
          {wishlist.can_follow ? (
            <a onClick={() => void toggleFollowing()} className="actions" role="button" aria-disabled={isLoading}>
              <Icon name={isFollowing ? "bookmark-check-fill" : "bookmark-plus"} />
            </a>
          ) : null}
        </footer>
      </section>
    </article>
  );
};

export const CardGrid = ({ children }: { children: React.ReactNode }) => (
  <div className="@container">
    <div className="grid gap-4 @lg:grid-cols-2">{children}</div>
  </div>
);

export const DummyCardGrid = ({ count }: { count: number }) => (
  <CardGrid>
    {Array(count)
      .fill(0)
      .map((_, i) => (
        <div key={i} className="dummy" style={{ aspectRatio: "3 / 1", paddingBottom: 0 }} />
      ))}
  </CardGrid>
);
