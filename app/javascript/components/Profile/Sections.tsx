import { Archive, ArrowUpRight } from "@boxicons/react";
import classNames from "classnames";
import * as React from "react";

import {
  FeaturedProductSection as SavedFeaturedProductSection,
  PostsSection as SavedPostsSection,
  ProductsSection as SavedProductsSection,
  RichTextSection as SavedRichTextSection,
  SubscribeSection as SavedSubscribeSection,
  WishlistsSection as SavedWishlistsSection,
} from "$app/data/profile_settings";
import { SearchResults } from "$app/data/search";
import { CreatorProfile } from "$app/parsers/profile";
import { CurrencyCode } from "$app/utils/currency";
import { formatPostDate } from "$app/utils/date";
import { fetchWithOneRetry, lazyWithRetry } from "$app/utils/lazy_chunk";

import { FallbackOnError } from "$app/components/FallbackOnError";
import { Product, Props as ProductProps } from "$app/components/Product";
import { CardGrid, useSearchReducer } from "$app/components/Product/CardGrid";
import { CoffeeProduct } from "$app/components/Product/CoffeeProduct";
import { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { useSelectionDiscounts } from "$app/components/Product/selectionDiscounts";
import { FollowForm } from "$app/components/Profile/FollowForm";
import { CardContent } from "$app/components/ui/Card";
import { Input } from "$app/components/ui/Input";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Card as WishlistCard, CardGrid as WishlistCardGrid, CardWishlist } from "$app/components/Wishlist/Card";

type BaseSection = {
  id: string;
  header: string | null;
};

type ProductsSection = BaseSection &
  Pick<SavedProductsSection, "type" | "show_filters" | "default_product_sort"> & {
    search_results: SearchResults;
    exclude_ids?: string[];
  };

export type Post = { id: string; slug: string; name: string; published_at: string | null };
type PostsSection = BaseSection & {
  type: SavedPostsSection["type"];
  posts: Post[];
};

type RichTextSection = BaseSection & Pick<SavedRichTextSection, "type" | "text">;

type SubscribeSection = BaseSection & Pick<SavedSubscribeSection, "type" | "button_label">;

type FeaturedProductSection = BaseSection & Pick<SavedFeaturedProductSection, "type"> & { props: ProductProps | null };

type WishlistsSection = BaseSection & Pick<SavedWishlistsSection, "type"> & { wishlists: CardWishlist[] };

export type Section =
  | ProductsSection
  | PostsSection
  | RichTextSection
  | SubscribeSection
  | FeaturedProductSection
  | WishlistsSection;

export const PostsView = ({ posts }: { posts: Post[] }) => {
  const userAgentInfo = useUserAgentInfo();
  return (
    <>
      {posts.map((post) => (
        <a
          key={post.slug}
          href={Routes.custom_domain_view_post_path(post.slug)}
          className="flex justify-between gap-4 border-b border-border py-8 no-underline first:pt-0 last:border-b-0 last:pb-0"
        >
          <div>
            <h2>{post.name}</h2>
            <time>{formatPostDate(post.published_at, userAgentInfo.locale)}</time>
          </div>
          <ArrowUpRight className="size-5 text-lg" />
        </a>
      ))}
    </>
  );
};

export const SubscribeView = ({
  creatorProfile,
  buttonLabel,
}: {
  creatorProfile: CreatorProfile;
  buttonLabel: string;
}) => (
  <div style={{ maxWidth: "500px" }}>
    <FollowForm creatorProfile={creatorProfile} buttonLabel={buttonLabel} buttonColor="primary" />
  </div>
);

const ProductsSectionView = ({
  section,
  creatorProfile,
  currencyCode,
}: {
  section: ProductsSection;
  creatorProfile: CreatorProfile;
  currencyCode: CurrencyCode;
}) => {
  const defaultParams = {
    sort: section.default_product_sort,
    user_id: creatorProfile.external_id,
    section_id: section.id,
    ...(section.exclude_ids?.length ? { exclude_ids: section.exclude_ids } : {}),
  };
  const [state, dispatch] = useSearchReducer({
    params: defaultParams,
    results: section.search_results,
  });
  const [enteredQuery, setEnteredQuery] = React.useState("");

  return (
    <CardGrid
      hideFilters={!section.show_filters}
      state={state}
      dispatchAction={dispatch}
      title={
        state.results
          ? state.results.total > 0
            ? `1-${state.results.products.length} of ${state.results.total} products`
            : "No products found"
          : "Loading products..."
      }
      currencyCode={currencyCode}
      defaults={defaultParams}
      prependFilters={
        <CardContent>
          <Input
            aria-label="Search products"
            placeholder="Search products"
            value={enteredQuery}
            onChange={(e) => setEnteredQuery(e.target.value)}
            onKeyPress={(e) => {
              if (e.key === "Enter") {
                const { from: _, ...params } = state.params;
                dispatch({ type: "set-params", params: { ...params, query: enteredQuery } });
              }
            }}
            className="grow"
          />
        </CardContent>
      }
    />
  );
};

export const FeaturedProductView = ({ props }: { props: ProductProps }) => {
  const [selection, setSelection] = React.useState<PriceSelection>({
    recurrence: props.product.recurrences?.default ?? null,
    price: { error: false, value: null },
    quantity: 1,
    rent: false,
    optionId: null,
    callStartTime: null,
    payInInstallments: false,
  });
  const { discountCode, saleLabel, selectionDiscountCode, quote } = useSelectionDiscounts({
    product: props.product,
    discountCode: props.discount_code,
    saleLabel: props.sale_label ?? null,
    initial: props.selection_discounts,
    selection,
  });
  return props.product.native_type === "coffee" ? (
    <CoffeeProduct {...props} />
  ) : (
    <Product
      {...props}
      discountCode={discountCode}
      saleLabel={saleLabel}
      selectionDiscountCode={selectionDiscountCode}
      quote={quote}
      selection={selection}
      setSelection={setSelection}
      scaleLongTitle={false}
    />
  );
};

export const WishlistsView = ({ wishlists }: { wishlists: CardWishlist[] }) =>
  wishlists.length > 0 ? (
    <WishlistCardGrid>
      {wishlists.map((wishlist) => (
        <WishlistCard key={wishlist.id} wishlist={wishlist} hideSeller />
      ))}
    </WishlistCardGrid>
  ) : (
    <div className="flex h-full flex-col content-center gap-4 text-center">
      <h1>
        <Archive pack="filled" className="size-5" />
      </h1>
      No wishlists selected
    </div>
  );

export const WishlistsSectionView = ({ section }: { section: WishlistsSection }) => (
  <WishlistsView wishlists={section.wishlists} />
);

const FeaturedProductSectionView = ({ section }: { section: FeaturedProductSection }) =>
  section.props ? <FeaturedProductView props={section.props} /> : null;

const PostsSectionView = ({ section }: { section: PostsSection }) => <PostsView posts={section.posts} />;

// Rich text sections are Tiptap JSON with no stored HTML to show first, so the page holds until the
// editor arrives (see LoggedInUserLayout). Pages without one never download it.
const importRichTextSection = () => import("$app/components/Profile/RichTextSection");
const LazyRichTextSection = lazyWithRetry(importRichTextSection, (module) => module.RichTextSection);

// Offline, the import would fail and React.lazy would keep that failure for the rest of the visit.
export const warmRichTextSection = () => {
  if (navigator.onLine) void fetchWithOneRetry(importRichTextSection).catch(() => {});
};

const RichTextSectionView = ({ section }: { section: RichTextSection }) => (
  <FallbackOnError fallback={null}>
    <LazyRichTextSection text={section.text} />
  </FallbackOnError>
);

const SubscribeSectionView = ({
  section,
  creatorProfile,
}: {
  section: SubscribeSection;
  creatorProfile: CreatorProfile;
}) => <SubscribeView creatorProfile={creatorProfile} buttonLabel={section.button_label} />;

export type PageProps = {
  currency_code: CurrencyCode;
  creator_profile: CreatorProfile;
  sections: Section[];
};

export const SectionLayout = ({
  children,
  className,
  ...props
}: { children: React.ReactNode } & React.ComponentProps<"section">) => (
  <section className={classNames("relative border-b border-border px-4 py-8 lg:py-16", className)} {...props}>
    <div className="mx-auto grid w-full max-w-6xl gap-6">{children}</div>
  </section>
);

export const Section = ({ section, creator_profile, currency_code }: { section: Section } & PageProps) => (
  <SectionLayout id={section.id}>
    {section.header ? <h2>{section.header}</h2> : null}
    {section.type === "SellerProfileProductsSection" ? (
      <ProductsSectionView section={section} creatorProfile={creator_profile} currencyCode={currency_code} />
    ) : section.type === "SellerProfilePostsSection" ? (
      <PostsSectionView section={section} />
    ) : section.type === "SellerProfileRichTextSection" ? (
      <RichTextSectionView section={section} />
    ) : section.type === "SellerProfileSubscribeSection" ? (
      <SubscribeSectionView key={section.id} section={section} creatorProfile={creator_profile} />
    ) : section.type === "SellerProfileFeaturedProductSection" ? (
      <FeaturedProductSectionView key={section.id} section={section} />
    ) : (
      <WishlistsSectionView key={section.id} section={section} />
    )}
  </SectionLayout>
);
