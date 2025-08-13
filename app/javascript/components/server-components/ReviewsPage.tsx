import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Popover } from "$app/components/Popover";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewForm } from "$app/components/ReviewForm";
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

let newReviewId = 0;

const ReviewsPage = ({
  reviews: initialReviews,
  purchases: initialPurchases,
  following_wishlists_enabled,
}: {
  reviews: Review[];
  purchases: { id: string; email_digest: string; product: Product }[];
  following_wishlists_enabled: boolean;
}) => {
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
        <section className="paragraphs">
          <h2>{`${purchases.length} ${purchases.length === 1 ? "product" : "products"} awaiting review`}</h2>
          <div
            className="grid"
            style={{
              "--max-grid-relative-size": "33%",
              "--min-grid-absolute-size": "18rem",
            }}
          >
            {purchases.map((purchase) => (
              <div className="cart h-min" role="list" key={purchase.id}>
                <div key={purchase.id} role="listitem">
                  <section>
                    <figure>
                      <Thumbnail url={purchase.product.thumbnail_url} nativeType={purchase.product.native_type} />
                    </figure>
                    <section>
                      <a href={purchase.product.url}>
                        <h4>{purchase.product.name}</h4>
                      </a>
                      <a href={purchase.product.seller.url}>{purchase.product.seller.name}</a>
                    </section>
                    <section />
                  </section>
                  <section className="footer">
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
                  </section>
                </div>
              </div>
            ))}
          </div>
        </section>
      ) : reviews.length > 0 ? (
        <section>
          <div className="placeholder">
            <h2>You've reviewed all your products!</h2>
            <NavigationButton href={discoverUrl} color="accent">
              Discover more
            </NavigationButton>
          </div>
        </section>
      ) : null}
      <section>
        {reviews.length === 0 ? (
          <div className="placeholder">
            <figure>
              <img src={placeholderImage} />
            </figure>
            <h2>You haven't bought anything... yet!</h2>
            Once you do, it'll show up here so you can review them.
            <NavigationButton href={discoverUrl} color="accent">
              Discover products
            </NavigationButton>
            <a href="#" data-helper-prompt="What are reviews and how can I remove reviews I've written?">
              Learn more about reviews.
            </a>
          </div>
        ) : (
          <table>
            <caption>Your reviews</caption>
            <tbody>
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
            </tbody>
          </table>
        )}
      </section>
    </Layout>
  );
};

const Row = ({ review, onChange }: { review: Review; onChange: (review: Review) => void }) => {
  const [isEditing, setIsEditing] = React.useState(false);

  return (
    <tr>
      <td className="icon-cell">
        <a href={review.product.url}>
          {review.product.thumbnail_url ? (
            <img alt={review.product.name} src={review.product.thumbnail_url} />
          ) : (
            <img src={cast(nativeTypeThumbnails(`./${review.product.native_type}.svg`))} />
          )}
        </a>
      </td>
      <td style={{ wordWrap: "break-word" }}>
        <div>
          <a href={review.product.url} target="_blank" rel="noreferrer">
            <h4>{review.product.name}</h4>
          </a>
          By{" "}
          <a href={review.product.seller.url} target="_blank" rel="noreferrer">
            {review.product.seller.name}
          </a>
        </div>
      </td>
      <td style={{ whiteSpace: "nowrap" }} aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}>
        <RatingStars rating={review.rating} />
      </td>
      <td style={{ wordWrap: "break-word" }}>{review.message ? `"${review.message}"` : null}</td>
      <td>
        <div className="actions">
          <Popover
            open={isEditing}
            onToggle={setIsEditing}
            trigger={
              <Button aria-label="Edit">
                <Icon name="pencil" />
              </Button>
            }
          >
            <div className="stack">
              <ReviewForm
                permalink={review.product.permalink}
                purchaseId={review.purchase_id}
                purchaseEmailDigest={review.purchase_email_digest}
                review={review}
                onChange={(newReview) => onChange({ ...review, ...newReview })}
              />
            </div>
          </Popover>
        </div>
      </td>
    </tr>
  );
};

export default register({ component: ReviewsPage, propParser: createCast() });
