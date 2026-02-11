import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";

import { Button, NavigationButton } from "$app/components/Button";
import { CartItem, CartItemList, CartItemMain, CartItemMedia, CartItemTitle } from "$app/components/CartItemList";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { ProductIconCell } from "$app/components/ProductsPage/ProductIconCell";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewForm } from "$app/components/ReviewForm";
import { Card } from "$app/components/ui/Card";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCaption, TableCell, TableRow } from "$app/components/ui/Table";
import { useOnChange } from "$app/components/useOnChange";

import placeholderImage from "$assets/images/placeholders/reviews.png";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

type Product = {
  name: string;
  url: string;
  permalink: string;
  thumbnail_url: string | null;
  native_type: ProductNativeType;
  seller: {
    name: string;
    url: string;
  };
};

type Review = {
  id: string;
  rating: number;
  message: string | null;
  purchase_id: string;
  purchase_email_digest: string;
  product: Product;
  video: {
    id: string;
    thumbnail_url: string | null;
  } | null;
};

interface Props {
  reviews: Review[];
  purchases: { id: string; email_digest: string; product: Product }[];
  following_wishlists_enabled: boolean;
}

let newReviewId = 0;

const Row = ({ review, onChange }: { review: Review; onChange: (review: Review) => void }) => {
  const [isEditing, setIsEditing] = React.useState(false);

  return (
    <TableRow>
      <ProductIconCell
        href={review.product.url}
        thumbnail={review.product.thumbnail_url ?? null}
        placeholder={<img src={cast(nativeTypeThumbnails(`./${review.product.native_type}.svg`))} />}
      />
      <TableCell className="break-words">
        <div>
          <a href={review.product.url} target="_blank" rel="noreferrer">
            <h4>{review.product.name}</h4>
          </a>
          By{" "}
          <a href={review.product.seller.url} target="_blank" rel="noreferrer">
            {review.product.seller.name}
          </a>
        </div>
      </TableCell>
      <TableCell
        className="whitespace-nowrap"
        aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}
      >
        <RatingStars rating={review.rating} />
      </TableCell>
      <TableCell className="break-words">{review.message ? `"${review.message}"` : null}</TableCell>
      <TableCell>
        <div className="flex flex-wrap gap-3 lg:justify-end">
          <Popover open={isEditing} onOpenChange={setIsEditing}>
            <PopoverAnchor>
              <PopoverTrigger aria-label="Edit" asChild>
                <Button>
                  <Icon name="pencil" />
                </Button>
              </PopoverTrigger>
            </PopoverAnchor>
            <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
              <Card>
                <ReviewForm
                  permalink={review.product.permalink}
                  purchaseId={review.purchase_id}
                  purchaseEmailDigest={review.purchase_email_digest}
                  review={review}
                  onChange={(newReview) => onChange({ ...review, ...newReview })}
                  className="flex flex-wrap items-center justify-between gap-4 p-4"
                />
              </Card>
            </PopoverContent>
          </Popover>
        </div>
      </TableCell>
    </TableRow>
  );
};

export default function ReviewsIndex({
  reviews: initialReviews,
  purchases: initialPurchases,
  following_wishlists_enabled,
}: Props) {
  const discoverUrl = useDiscoverUrl();

  const [reviews, setReviews] = React.useState(initialReviews);
  const [purchases, setPurchases] = React.useState(initialPurchases);

  const inputRefs = React.useRef<Record<string, HTMLTextAreaElement | null>>({});

  useOnChange(() => {
    if (!purchases[0]) return;
    inputRefs.current[purchases[0].id]?.focus();
  }, [purchases.length]);

  return (
    <Layout selectedTab="reviews" followingWishlistsEnabled={following_wishlists_enabled}>
      {purchases.length ? (
        <section className="@container space-y-4 p-4 md:p-8">
          <h2>{`${purchases.length} ${purchases.length === 1 ? "product" : "products"} awaiting review`}</h2>
          <div className="grid gap-4 @xl:grid-cols-2 @4xl:grid-cols-3">
            {purchases.map((purchase) => (
              <CartItemList className="h-min" key={purchase.id}>
                <CartItem
                  extra={
                    <ReviewForm
                      permalink={purchase.product.permalink}
                      purchaseId={purchase.id}
                      purchaseEmailDigest={purchase.email_digest}
                      review={null}
                      onChange={(newReview) => {
                        setReviews((prevReviews) => [
                          ...prevReviews,
                          {
                            ...purchase,
                            ...newReview,
                            id: (newReviewId++).toString(),
                            review: newReview,
                            purchase_id: purchase.id,
                            purchase_email_digest: purchase.email_digest,
                          },
                        ]);
                        setPurchases((prevPurchases) =>
                          prevPurchases.filter((prevPurchase) => prevPurchase.id !== purchase.id),
                        );
                      }}
                      style={{ display: "grid", gap: "var(--spacer-4)" }}
                      ref={(el) => (inputRefs.current[purchase.id] = el)}
                    />
                  }
                  key={purchase.id}
                >
                  <CartItemMedia>
                    <Thumbnail url={purchase.product.thumbnail_url} nativeType={purchase.product.native_type} />
                  </CartItemMedia>
                  <CartItemMain>
                    <CartItemTitle asChild>
                      <a href={purchase.product.url}>
                        <h4 className="font-bold">{purchase.product.name}</h4>
                      </a>
                    </CartItemTitle>
                    <CartItemTitle className="font-normal" asChild>
                      <a href={purchase.product.seller.url}>{purchase.product.seller.name}</a>
                    </CartItemTitle>
                  </CartItemMain>
                </CartItem>
              </CartItemList>
            ))}
          </div>
        </section>
      ) : reviews.length > 0 ? (
        <section className="p-4 md:p-8">
          <Placeholder>
            <h2>You've reviewed all your products!</h2>
            <NavigationButton href={discoverUrl} color="accent">
              Discover more
            </NavigationButton>
          </Placeholder>
        </section>
      ) : null}
      <section className="p-4 md:p-8">
        {reviews.length === 0 && purchases.length === 0 ? (
          <Placeholder>
            <PlaceholderImage src={placeholderImage} />
            <h2>You haven't bought anything... yet!</h2>
            Once you do, it'll show up here so you can review them.
            <NavigationButton href={discoverUrl} color="accent">
              Discover products
            </NavigationButton>
            <a href="/help/article/344-rate-and-review-your-purchase" target="_blank" rel="noreferrer">
              Learn more about reviews
            </a>
          </Placeholder>
        ) : reviews.length > 0 ? (
          <Table>
            <TableCaption>Your reviews</TableCaption>
            <TableBody>
              {reviews.map((review) => (
                <Row
                  key={review.id}
                  review={review}
                  onChange={(review) =>
                    setReviews((prevReviews) =>
                      prevReviews.map((prevReview) => (review.id === prevReview.id ? review : prevReview)),
                    )
                  }
                />
              ))}
            </TableBody>
          </Table>
        ) : null}
      </section>
    </Layout>
  );
}
