import { Discount as DiscountIcon, Star } from "@boxicons/react";
import { differenceInYears, parseISO } from "date-fns";
import * as React from "react";

import { getReviews, type Review } from "$app/data/product_reviews";
import { trackUserProductAction } from "$app/data/user_action_event";
import { incrementProductViews } from "$app/data/view_event";
import { Wishlist } from "$app/data/wishlists";
import { Discount } from "$app/parsers/checkout";
import {
  AnalyticsData,
  AssetPreview,
  BuyerCurrencyDisplay,
  COMMISSION_DEPOSIT_PROPORTION,
  CustomButtonTextOption,
  FreeTrial,
  ProductNativeType,
  Ratings,
  RatingsWithPercentages,
} from "$app/parsers/product";
import { SellerReputation } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";
import {
  BuyerLocalCurrencyContext,
  CurrencyCode,
  formatBuyerLocalOrSetPrice,
  formatPriceCentsWithCurrencySymbol,
} from "$app/utils/currency";
import { formatDate } from "$app/utils/date";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";
import { variantLabel } from "$app/utils/labels";
import { isSingleChargeDuration, renewalReminderNotice } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";
import { startTrackingForSeller, trackBuyerCurrencyDisplayView, trackProductEvent } from "$app/utils/user_analytics";

import { Button, NavigationButton } from "$app/components/Button";
import {
  CartItem,
  CartItemEnd,
  CartItemFooter,
  CartItemList,
  CartItemMain,
  CartItemMedia,
  CartItemTitle,
} from "$app/components/CartItemList";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useDomains } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { PaginationProps } from "$app/components/Pagination";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { CollapsibleDescription } from "$app/components/Product/CollapsibleDescription";
import {
  applySelection,
  buyerLocalPriceCentsForSelection,
  buyerLocalContextFor,
  ConfigurationSelector,
  ConfigurationSelectorHandle,
  getMaxQuantity,
  Option,
  PriceSelection,
  PurchasingPowerParityDetails,
  Recurrences,
  Rental,
  withConfiguredOncePerCartAmount,
} from "$app/components/Product/ConfigurationSelector";
import { Covers as CoversComponent } from "$app/components/Product/Covers";
import { DiscountExpirationCountdown } from "$app/components/Product/DiscountExpirationCountdown";
import { LazyDescription } from "$app/components/Product/LazyDescription";
import { PriceTag } from "$app/components/Product/PriceTag";
import { getBundleComparisonPriceCents, getStandalonePrice } from "$app/components/Product/pricing";
import { PurchaseButton } from "$app/components/Product/PurchaseButton";
import { initialOptionId } from "$app/components/Product/purchaseReadiness";
import { Ribbon } from "$app/components/Product/Ribbon";
import type { SelectionDiscounts, SelectionQuote } from "$app/components/Product/selectionDiscounts";
import { ShareSection } from "$app/components/Product/ShareSection";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { InstallmentPlan } from "$app/components/ProductEdit/state";
import { RatingStars } from "$app/components/RatingStars";
import { Review as ReviewComponent } from "$app/components/Review";
import { Review as FormReview, ReviewForm } from "$app/components/ReviewForm";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { LinkButton } from "$app/components/ui/LinkButton";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useOnChange } from "$app/components/useOnChange";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

export type Seller = { id: string; name: string; avatar_url: string; profile_url: string; is_verified: boolean };

type RefundPolicy = {
  title: string;
  fine_print: string | null;
  updated_at: string;
};

export type PublicFile = {
  id: string;
  name: string;
  extension: string | null;
  file_size: number | null;
  url: string | null;
};

export type Product = {
  id: string;
  name: string;
  seller: Seller | null;
  collaborating_user: Seller | null;
  covers: AssetPreview[];
  main_cover_id: string | null;
  quantity_remaining: number | null;
  currency_code: CurrencyCode;
  long_url: string;
  duration_in_months: number | null;
  is_sales_limited: boolean;
  price_cents: number;
  buyer_currency?: string;
  buyer_local_currency_rate?: number;
  buyer_local_currency_subunit_to_unit?: number;
  buyer_local_price_cents?: number;
  buyer_local_original_price_cents?: number;
  buyer_currency_display?: BuyerCurrencyDisplay;
  pwyw: { suggested_price_cents: number | null; default_price_cents?: number | null } | null;
  installment_plan: InstallmentPlan | null;
  ratings: RatingsWithPercentages | null;
  // Present only while seller_reputation_summary is on for the seller. Always
  // excludes this product's own reviews (hence "other products" in the copy).
  seller_reputation?: SellerReputation | null;
  is_legacy_subscription: boolean;
  is_tiered_membership: boolean;
  is_recurring_billing: boolean;
  is_physical: boolean;
  custom_view_content_button_text: string | null;
  custom_button_text_option: "" | CustomButtonTextOption | null;
  permalink: string;
  preorder: { release_date: string } | null;
  description_html: string | null;
  is_compliance_blocked: boolean;
  is_published: boolean;
  is_stream_only: boolean;
  streamable: boolean;
  is_quantity_enabled: boolean;
  is_multiseat_license: boolean;
  is_licensed: boolean;
  hide_sold_out_variants?: boolean;
  native_type: ProductNativeType;
  sales_count: number | null;
  summary: string | null;
  attributes: { name: string; value: string }[];
  free_trial: FreeTrial | null;
  rental: Rental | null;
  recurrences: Recurrences | null;
  options: Option[];
  analytics: AnalyticsData;
  has_third_party_analytics: boolean;
  ppp_details: PurchasingPowerParityDetails | null;
  can_edit: boolean;
  refund_policy: RefundPolicy | null;
  bundle_products: {
    id: string;
    name: string;
    ratings: Ratings | null;
    price: number;
    currency_code: CurrencyCode;
    thumbnail_url: string | null;
    native_type: ProductNativeType;
    url: string;
    quantity: number;
    variant: string | null;
  }[];
  public_files: PublicFile[];
};
export type Purchase = {
  id: string;
  email_digest: string;
  created_at: string;
  review: FormReview | null;
  review_account_name: string | null;
  should_show_receipt: boolean;
  was_paid: boolean;
  is_gift_receiver_purchase: boolean;
  content_url: string | null;
  show_view_content_button_on_product_page: boolean;
  total_price_including_tax_and_shipping: string;
  subscription_has_lapsed: boolean;
  membership: { tier_name: string | null; tier_description: string | null; manage_url: string } | null;
  // Present only for licensed products, and only when the backend could identify the
  // visitor (signed-in purchaser, or an HMAC'd receipt/review link). Purchases matched
  // by the browser cookie alone never carry the key — Link#purchase_info_for_product_page
  // strips it, because a cookie identifies a browser rather than a person. Optional
  // rather than nullable because the strip removes the key entirely.
  license_key?: string | null;
};
export type ProductDiscount =
  | {
      valid: false;
      error_code:
        | "sold_out"
        | "invalid_offer"
        | "inactive"
        | "unmet_minimum_purchase_quantity"
        | "not_existing_customer";
    }
  | { valid: true; code: string; discount: Discount }
  | null;

export const getNotForSaleMessage = (product: Product) =>
  product.is_compliance_blocked
    ? "Sorry, this item is not available in your location."
    : product.quantity_remaining === 0
      ? "Sold out, please go back and pick another option."
      : !product.is_published
        ? "This product is not currently for sale."
        : null;

export type WishlistForProduct = Wishlist & {
  selections_in_wishlist: { variant_id: string | null; recurrence: string | null; rent: boolean; quantity: number }[];
};

export const formatDiscountAmount = (discount: Discount, buyerLocalContext: BuyerLocalCurrencyContext) => {
  if (discount.type === "percent") {
    return discount.tiered && discount.min_percents !== undefined && discount.max_percents !== undefined
      ? discount.min_percents === discount.max_percents
        ? `${discount.max_percents}%`
        : `${discount.min_percents}%–${discount.max_percents}%`
      : `${discount.percents}%`;
  }

  return formatBuyerLocalOrSetPrice(discount.once_per_cart_amount_cents ?? discount.cents, buyerLocalContext, {
    symbolFormat: "long",
  });
};

export const useSelectionFromUrl = (product: Product) => {
  const { searchParams } = new URL(useOriginalLocation());
  return React.useState<PriceSelection>(() => {
    const recurrence =
      product.recurrences?.enabled.find(
        // support legacy ?yearly=true parameters
        ({ recurrence }) => recurrence === searchParams.get("recurrence") || searchParams.get(recurrence),
      )?.recurrence ??
      product.recurrences?.default ??
      null;
    const parsedOption = product.options.find(
      // support legacy variant=name parameter
      ({ id, name }) => id === searchParams.get("option") || name === searchParams.get("variant"),
    );
    const parsedQuantity = Number(searchParams.get("quantity"));
    const optionId = initialOptionId(product, searchParams);
    const parsedPrice = Number(searchParams.get("price") ?? undefined);
    const parsedCallStartTime = new Date(searchParams.get("call_start_time") ?? "");
    const parsedPayInInstallments = searchParams.get("pay_in_installments") === "true" && !!product.installment_plan;
    return {
      recurrence,
      rent: product.rental?.rent_only ?? false,
      optionId,
      quantity:
        (product.is_quantity_enabled || product.is_multiseat_license) && parsedQuantity > 0
          ? Math.min(parsedQuantity, getMaxQuantity(product, parsedOption ?? null) ?? Infinity)
          : 1,
      price: {
        value:
          parsedPrice >= 0
            ? parsedPrice * 100
            : searchParams.has("price")
              ? null
              : (product.pwyw?.default_price_cents ?? null),
        error: false,
      },
      callStartTime: isNaN(parsedCallStartTime.getTime()) ? null : parsedCallStartTime.toISOString(),
      payInInstallments: parsedPayInInstallments,
    };
  });
};

export type Props = {
  product: Product;
  purchase: Purchase | null;
  discount_code: ProductDiscount | null;
  sale_label?: string | null;
  selection_discounts?: SelectionDiscounts | null;
  wishlists: WishlistForProduct[];
};

// Past this many characters the 40px title wraps to three or more lines on a standard product page.
export const LONG_TITLE_LENGTH = 60;

export const Product = ({
  product,
  purchase,
  discountCode: initialDiscountCode,
  saleLabel,
  selectionDiscountCode,
  quote,
  ctaLabel,
  selection,
  setSelection,
  ctaButtonRef,
  configurationSelectorRef,
  wishlists = [],
  disableAnalytics,
  hideSellerByline,
  scaleLongTitle = true,
}: {
  product: Product;
  purchase: Purchase | null;
  discountCode?: ProductDiscount | null;
  // The seller's sale label; only sent when the displayed discount is their auto-applied code.
  saleLabel?: string | null | undefined;
  // The server's code for each option and for renting, when they get different ones; see useSelectionDiscounts.
  selectionDiscountCode?: ((optionId: string | null, rent: boolean) => ProductDiscount | null) | undefined;
  // Whether the codes above were quoted for the current selection; the buy buttons wait until they are.
  quote?: SelectionQuote | undefined;
  ctaLabel?: string | undefined;
  selection: PriceSelection;
  setSelection?: React.Dispatch<React.SetStateAction<PriceSelection>>;
  ctaButtonRef?: React.MutableRefObject<HTMLAnchorElement | null>;
  configurationSelectorRef?: React.MutableRefObject<ConfigurationSelectorHandle | null>;
  wishlists?: WishlistForProduct[];
  disableAnalytics?: boolean;
  // The storefront-wrapped product page renders the profile header directly above, which
  // already shows the same avatar and name — the byline is redundant there.
  hideSellerByline?: boolean | undefined;
  // Long titles step down to 32px (24px on phones) on standard product pages. Surfaces that reuse
  // this component under another heading, like the featured product on a profile, opt out.
  scaleLongTitle?: boolean;
}) => {
  const notForSaleMessage = getNotForSaleMessage(product);
  // Kept by code, so another option's quote for an expired code cannot bring it back.
  const [expiredCodes, setExpiredCodes] = React.useState<string[]>([]);
  const isExpired = (code: ProductDiscount | null | undefined) => !!code?.valid && expiredCodes.includes(code.code);
  const discountCode: ProductDiscount | null | undefined = isExpired(initialDiscountCode)
    ? { valid: false, error_code: "inactive" }
    : initialDiscountCode;

  const discount = discountCode?.valid ? discountCode.discount : null;
  const renewalNotice =
    selection.recurrence && !isSingleChargeDuration(selection.recurrence, product.duration_in_months ?? null)
      ? renewalReminderNotice(product.recurrences, selection.recurrence)
      : null;
  const selectionAttributes = applySelection(product, discount, selection);
  let { basePriceCents } = selectionAttributes;
  const { priceCents, discountedPriceCents, pppDiscounted, maxQuantity, selectedOption } = selectionAttributes;
  React.useEffect(() => {
    if (maxQuantity !== null && selection.quantity > maxQuantity)
      setSelection?.({ ...selection, quantity: maxQuantity });
  }, [maxQuantity, selection.quantity]);

  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();

  const { searchParams } = new URL(useOriginalLocation());
  useRunOnce(() => {
    if (disableAnalytics) return;
    if (product.seller) {
      startTrackingForSeller(product.seller.id, product.analytics);
      trackBuyerCurrencyDisplayView(product.seller.id, product.buyer_currency_display);
      trackProductEvent(product.seller.id, {
        permalink: product.permalink,
        action: "viewed",
        product_name: product.name,
      });
    } else {
      trackBuyerCurrencyDisplayView(undefined, product.buyer_currency_display);
    }
    void incrementProductViews({ permalink: product.permalink, recommendedBy: searchParams.get("recommended_by") });
    if (product.has_third_party_analytics)
      addThirdPartyAnalytics({ permalink: product.permalink, location: "product" });
  });

  const isBundle = product.bundle_products.length > 0;
  if (isBundle) basePriceCents = getStandalonePrice(product);
  // Paid bundle tiers have no standalone comparison; basePriceCents still controls price visibility.
  const comparisonPriceCents = isBundle ? getBundleComparisonPriceCents(product, selectedOption) : basePriceCents;

  // The storefront-wrapped page's profile header already shows the seller, but not a
  // collaborator — keep the byline when there is one so the "with X" context survives.
  const sellerByline =
    product.seller && !(hideSellerByline && !product.collaborating_user) ? (
      <AuthorByline
        name={product.seller.name}
        profileUrl={product.seller.profile_url}
        avatarUrl={product.seller.avatar_url}
        isTopCreator={product.seller.is_verified}
      />
    ) : null;

  const showPrice =
    !product.recurrences &&
    product.options.length === 0 &&
    !product.rental?.rent_only &&
    (basePriceCents !== 0 || product.pwyw);

  const hasRatings = product.ratings != null && product.ratings.count > 0;

  // The label names the price the buyer sees, so it shows only while the code produced that price.
  // applySelection already drops a code whose minimum quantity or amount this selection misses.
  const codeDiscounts = (attributes: typeof selectionAttributes) =>
    !attributes.pppDiscounted && attributes.discountedPriceCents < attributes.priceCents;
  const sameCode = (left: ProductDiscount | null, right: ProductDiscount | null) =>
    !!left?.valid && !!right?.valid && left.code === right.code;
  // The code that prices a choice the buyer could make, such as another option row or the rent tab.
  const rowDiscount = (rowSelection: PriceSelection) => {
    if (!selectionDiscountCode || (rowSelection.optionId === null && product.options.length > 0)) return discount;
    const rowCode = selectionDiscountCode(rowSelection.optionId, rowSelection.rent);
    return rowCode?.valid && !isExpired(rowCode) ? withConfiguredOncePerCartAmount(rowCode.discount) : null;
  };
  // With no option picked, each visible option shows its own price, so any discounted one earns the label.
  const showSaleLabel =
    !!saleLabel &&
    !!discountCode?.valid &&
    (product.options.length > 0 && selectedOption === null
      ? product.options.some(
          (option) =>
            !(product.hide_sold_out_variants && option.quantity_left === 0) &&
            (!selectionDiscountCode || sameCode(selectionDiscountCode(option.id, selection.rent), discountCode)) &&
            codeDiscounts(
              applySelection(product, rowDiscount({ ...selection, optionId: option.id }), {
                ...selection,
                optionId: option.id,
              }),
            ),
        )
      : codeDiscounts(selectionAttributes));

  const hasDiscountTerms =
    discount &&
    (discount.minimum_quantity ||
      (discount.duration_in_billing_cycles && product.is_recurring_billing) ||
      discount.minimum_amount_cents ||
      discount.expires_at);

  const saleBanner =
    showSaleLabel && discount ? (
      <div
        role="status"
        data-testid="sale-banner"
        // Without covers, the desktop banner fills the card's top-right corner and follows its inner radius.
        className={classNames(
          "flex items-center gap-2 border-b border-border bg-accent-with-text px-6 py-3 font-bold text-accent-foreground",
          product.covers.length === 0 && "lg:rounded-tr-[calc(var(--radius)_-_var(--border-width))]",
        )}
      >
        <DiscountIcon pack="filled" className="size-5 shrink-0" aria-hidden="true" />
        <span className="min-w-0 wrap-break-word" data-testid="sale-label">
          {saleLabel}
        </span>
        <span className="ml-auto shrink-0">{formatDiscountAmount(discount, buyerLocalContextFor(product))} off</span>
      </div>
    ) : null;
  const priceTag = showPrice ? (
    <PriceTag
      currencyCode={product.currency_code}
      oldPrice={
        comparisonPriceCents !== null && discountedPriceCents < comparisonPriceCents ? comparisonPriceCents : undefined
      }
      price={discountedPriceCents}
      url={product.long_url}
      isPayWhatYouWant={!!product.pwyw}
      isSalesLimited={product.is_sales_limited}
      creatorName={product.seller?.name}
      buyerCurrency={product.buyer_currency}
      buyerLocalCurrencyRate={product.buyer_local_currency_rate}
      buyerLocalCurrencySubunitToUnit={product.buyer_local_currency_subunit_to_unit}
      buyerLocalPriceCents={buyerLocalPriceCentsForSelection(
        product.buyer_local_price_cents,
        discount,
        selection.quantity,
      )}
      buyerLocalOriginalPriceCents={product.buyer_local_original_price_cents}
    />
  ) : null;

  return (
    <article
      className={classNames(
        "relative grid rounded border border-border bg-background [grid-template-areas:'covers'_'title'_'price'_'details'_'controls'] lg:grid-cols-[2fr_1fr]",
        // The title spans two rows, so a tall title stretches the controls' row instead of the price row.
        // In one shared row, the controls would start below the title and leave a gap under the price.
        saleBanner || priceTag
          ? "lg:grid-rows-[auto_auto_auto_1fr] lg:[grid-template-areas:'covers_covers'_'title_price'_'title_controls'_'details_controls']"
          : "lg:grid-rows-[auto_auto_1fr] lg:[grid-template-areas:'covers_covers'_'title_controls'_'details_controls']",
      )}
    >
      <Covers covers={product.covers} mainCoverId={product.main_cover_id} productName={product.name} />
      {product.quantity_remaining !== null ? <Ribbon>{product.quantity_remaining} left</Ribbon> : null}
      <header className="grid gap-4 p-6 [grid-area:title] lg:border-r">
        {/* dir="auto" lets an RTL product name (Hebrew, Arabic) render right-to-left
              instead of inheriting the document's LTR base direction, which misplaces
              neutral characters like quotes and digits (gumroad-private#1259; same
              rationale as the description fix in #6138).
              wrap-break-word overrides the inherited global overflow-wrap: anywhere, which
              splits titles mid-word in narrow in-app browsers. */}
        <h1
          itemProp="name"
          dir="auto"
          className={classNames(
            "wrap-break-word",
            scaleLongTitle && product.name.trim().length > LONG_TITLE_LENGTH && "text-[2rem] max-sm:text-[1.5rem]",
          )}
        >
          {product.name}
        </h1>
      </header>
      {/* Align the desktop title and price so both layouts keep one accessible reading order. */}
      {saleBanner || priceTag ? (
        <section className="border-t [grid-area:price] lg:border-t-0">
          {saleBanner}
          {priceTag ? <div className="px-6 py-4 lg:pt-6 lg:pb-0">{priceTag}</div> : null}
        </section>
      ) : null}
      <div className="[grid-area:details] lg:border-r">
        {sellerByline || hasRatings ? (
          <section className="grid grid-cols-1 gap-[1px] border-t border-border p-0 sm:grid-cols-[minmax(0,1fr)_auto]">
            {sellerByline ? (
              <div
                className={classNames(
                  "flex min-w-0 flex-wrap items-center gap-2 px-6 py-4 outline outline-offset-0 outline-border",
                  !hasRatings && "sm:col-span-full",
                )}
              >
                {product.collaborating_user ? (
                  <>
                    {sellerByline} with{" "}
                    <AuthorByline
                      name={product.collaborating_user.name}
                      profileUrl={product.collaborating_user.profile_url}
                      avatarUrl={product.collaborating_user.avatar_url}
                    />
                  </>
                ) : (
                  sellerByline
                )}
              </div>
            ) : null}
            {product.ratings != null && hasRatings ? (
              <div
                className={classNames(
                  "flex items-center px-6 py-4 outline outline-offset-0 outline-border",
                  !sellerByline && "sm:col-span-full",
                )}
              >
                <RatingsSummary ratings={product.ratings} />
              </div>
            ) : null}
          </section>
        ) : null}
        {purchase !== null ? (
          <ExistingPurchaseCard
            purchase={purchase}
            permalink={product.permalink}
            isPreorder={product.preorder !== null}
            isBundle={isBundle}
            customViewContentButtonText={product.custom_view_content_button_text}
          />
        ) : null}
        {isBundle ? (
          <section className="grid gap-4 border-t border-border p-6">
            <h2>This bundle contains...</h2>
            <CartItemList>
              {product.bundle_products.map((bundleProduct) => {
                const price =
                  bundleProduct.currency_code === product.currency_code
                    ? formatBuyerLocalOrSetPrice(bundleProduct.price, {
                        currencyCode: product.currency_code,
                        buyerCurrency: product.buyer_currency,
                        buyerLocalCurrencyRate: product.buyer_local_currency_rate,
                        buyerLocalCurrencySubunitToUnit: product.buyer_local_currency_subunit_to_unit,
                      })
                    : formatPriceCentsWithCurrencySymbol(bundleProduct.currency_code, bundleProduct.price, {
                        symbolFormat: "long",
                      });
                return (
                  <CartItem key={bundleProduct.id} isBundleItem>
                    <CartItemMedia className="h-16 w-16 shrink-0 sm:h-28 sm:w-28">
                      <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
                    </CartItemMedia>
                    {/* Checkout's floor: without it a wide price squeezes this to one letter/line. */}
                    <CartItemMain className="min-h-16 min-w-2/5 sm:h-28">
                      <CartItemTitle asChild>
                        <a href={bundleProduct.url}>
                          <h4 className="font-bold wrap-break-word">{bundleProduct.name}</h4>
                        </a>
                      </CartItemTitle>
                      {bundleProduct.ratings ? (
                        <div className="line-clamp-1 flex shrink-0 items-center gap-1" aria-label="Rating">
                          <Star pack="filled" className="size-5" />
                          {`${bundleProduct.ratings.average.toFixed(1)} (${bundleProduct.ratings.count})`}
                        </div>
                      ) : null}
                      <span className="sr-only">Qty: {bundleProduct.quantity}</span>
                      {bundleProduct.variant ? (
                        <CartItemFooter>
                          <span className="line-clamp-1">
                            <strong>{variantLabel(bundleProduct.native_type)}:</strong> {bundleProduct.variant}
                          </span>
                        </CartItemFooter>
                      ) : null}
                    </CartItemMain>
                    <CartItemEnd className="max-w-1/2 shrink-0 flex-row items-start gap-4 p-4 text-right">
                      <span className="current-price whitespace-nowrap" aria-label="Price">
                        {comparisonPriceCents !== null && discountedPriceCents < comparisonPriceCents ? (
                          <s>{price}</s>
                        ) : (
                          price
                        )}
                      </span>
                    </CartItemEnd>
                  </CartItem>
                );
              })}
            </CartItemList>
          </section>
        ) : null}
        <section className="border-t border-border p-6">
          <CollapsibleDescription>
            <LazyDescription html={product.description_html} publicFiles={product.public_files} />
          </CollapsibleDescription>
        </section>
      </div>
      <section className="[grid-area:controls]">
        <section className="grid gap-4 border-t p-6 lg:border-t-0">
          {notForSaleMessage ? (
            <Alert role="status" variant="warning">
              {notForSaleMessage}
            </Alert>
          ) : product.native_type === "commission" ? (
            <Alert role="status" variant="info">
              Secure your order with a {`${COMMISSION_DEPOSIT_PROPORTION * 100}%`} deposit today; the remaining balance
              will be charged upon completion.
            </Alert>
          ) : null}
          {discountCode ? (
            discountCode.valid ? (
              (
                showSaleLabel
                  ? hasDiscountTerms
                  : (discountedPriceCents < priceCents ||
                      discountCode.discount.minimum_quantity ||
                      discountCode.discount.minimum_amount_cents ||
                      (discountCode.discount.type === "fixed" && discountCode.discount.once_per_cart)) &&
                    !pppDiscounted
              ) ? (
                <Alert role="status" variant="success">
                  <div className="flex flex-col gap-4">
                    {showSaleLabel ? (
                      discountCode.discount.minimum_quantity ? (
                        <div>Applies when you buy {discountCode.discount.minimum_quantity} or more.</div>
                      ) : null
                    ) : discountCode.discount.minimum_quantity ? (
                      `Get ${formatDiscountAmount(discountCode.discount, buyerLocalContextFor(product))} off when you buy ${discountCode.discount.minimum_quantity} or more (Code ${discountCode.code.toUpperCase()})`
                    ) : (
                      `${formatDiscountAmount(discountCode.discount, buyerLocalContextFor(product))} off will be applied at checkout (Code ${discountCode.code.toUpperCase()})`
                    )}
                    {discountCode.discount.duration_in_billing_cycles && product.is_recurring_billing ? (
                      <div>This discount will only apply to the first payment of your subscription.</div>
                    ) : null}
                    {discountCode.discount.minimum_amount_cents ? (
                      <div>
                        {(discountCode.discount.product_ids?.length ?? 0) === 1
                          ? `This discount will apply when you spend ${formatBuyerLocalOrSetPrice(
                              discountCode.discount.minimum_amount_cents,
                              buyerLocalContextFor(product),
                              { symbolFormat: "short" },
                            )} or more.`
                          : `This discount will apply when you spend ${formatBuyerLocalOrSetPrice(
                              discountCode.discount.minimum_amount_cents,
                              buyerLocalContextFor(product),
                              { symbolFormat: "short" },
                            )} or more in ${
                              !discountCode.discount.product_ids && product.seller
                                ? `${product.seller.name}'s`
                                : "selected"
                            } products.`}
                      </div>
                    ) : null}
                    {discountCode.discount.expires_at ? (
                      <DiscountExpirationCountdown
                        expiresAt={new Date(discountCode.discount.expires_at)}
                        showEndDate={showSaleLabel}
                        onExpiration={() => setExpiredCodes((codes) => [...codes, discountCode.code])}
                      />
                    ) : null}
                  </div>
                </Alert>
              ) : null
            ) : (
              <Alert role="status" variant="danger">
                {discountCode.error_code === "sold_out"
                  ? "Sorry, the discount code you wish to use has reached its usage limit."
                  : discountCode.error_code === "invalid_offer"
                    ? "Sorry, the discount code you wish to use is invalid."
                    : discountCode.error_code === "not_existing_customer"
                      ? "Sorry, this discount code is only for existing customers."
                      : "Sorry, the discount code you wish to use is inactive."}
              </Alert>
            )
          ) : null}
          <ConfigurationSelector
            product={product}
            selection={selection}
            setSelection={setSelection}
            discount={discountCode?.valid ? withConfiguredOncePerCartAmount(discountCode.discount) : null}
            rowDiscount={selectionDiscountCode ? rowDiscount : undefined}
            ref={configurationSelectorRef}
          />
          {product.ppp_details && pppDiscounted ? (
            <Alert role="status" variant="info">
              This product supports purchasing power parity. Because you're located in{" "}
              <b>{product.ppp_details.country}</b>, the price has been discounted by{" "}
              <b>
                {(Math.round((1 - discountedPriceCents / priceCents) * 100) / 100).toLocaleString(undefined, {
                  style: "percent",
                })}
              </b>{" "}
              to{" "}
              <b>
                {formatBuyerLocalOrSetPrice(discountedPriceCents, buyerLocalContextFor(product), {
                  symbolFormat: "long",
                })}
              </b>
              .
              {discountCode?.valid
                ? " This discount will be applied because it is greater than the offer code discount."
                : null}
            </Alert>
          ) : null}
          {product.free_trial ? (
            <Alert role="status" variant="info">
              All memberships include a {product.free_trial.duration.amount} {product.free_trial.duration.unit} free
              trial
            </Alert>
          ) : null}
          {product.duration_in_months ? (
            <Alert role="status" variant="info">
              This membership will automatically end after{" "}
              {product.duration_in_months === 1 ? "one month" : `${product.duration_in_months} months`}
            </Alert>
          ) : null}
          {renewalNotice ? (
            <p className="text-sm" role="note">
              {renewalNotice}
            </p>
          ) : null}
          {quote?.state === "failed" ? (
            <Alert role="alert" variant="danger">
              <div className="flex flex-col gap-4">
                We couldn't check the discount for this selection.
                <Button onClick={quote.retry}>Try again</Button>
              </div>
            </Alert>
          ) : null}
          <PurchaseButton
            ref={ctaButtonRef}
            product={product}
            purchase={purchase}
            discountCode={discountCode ?? null}
            pricePending={!!quote && quote.state !== "ready"}
            selection={selection}
            label={ctaLabel}
            showInstallmentPlanNotes
            setSelection={setSelection}
            configurationSelectorRef={configurationSelectorRef}
          />
          {purchase === null && !product.can_edit ? (
            <PurchaseRecoveryLink
              permalink={product.permalink}
              isLicensed={product.is_licensed}
              hasDownload={
                !product.is_physical && product.native_type !== "call" && product.native_type !== "commission"
              }
              disableAnalytics={disableAnalytics}
            />
          ) : null}
          {product.sales_count !== null ? (
            <Alert role="status" variant="info">
              <strong>{product.sales_count.toLocaleString()}</strong>{" "}
              {product.recurrences
                ? "member"
                : product.preorder
                  ? "pre-order"
                  : product.price_cents > 0 || product.options.some((option) => option.price_difference_cents)
                    ? "sale"
                    : "download"}
              {product.sales_count === 1 ? "" : "s"}
            </Alert>
          ) : null}
          {product.preorder ? (
            <Alert role="status" variant="info">
              Available on {formatDate(parseISO(product.preorder.release_date))}
            </Alert>
          ) : null}
          {product.streamable ? (
            <Alert role="status" variant="info">
              Video link provided after purchase
            </Alert>
          ) : null}
          {product.summary || product.attributes.length > 0 ? (
            <Card>
              {product.summary ? (
                <CardContent asChild>
                  <p>{product.summary}</p>
                </CardContent>
              ) : null}
              {product.attributes.map(({ name, value }, idx) => (
                <CardContent key={idx}>
                  <h5 className="grow font-bold">{name}</h5>
                  <div>{value}</div>
                </CardContent>
              ))}
            </Card>
          ) : null}
          <ShareSection product={product} selection={selection} wishlists={wishlists} />
          {product.refund_policy ? (
            <RefundPolicyInfo refundPolicy={product.refund_policy} permalink={product.permalink} />
          ) : null}
        </section>
        {product.ratings ? <Reviews ratings={product.ratings} productId={product.id} seller={product.seller} /> : null}
        {product.seller_reputation ? (
          <SellerReputationSection
            reputation={product.seller_reputation}
            hasOwnReviews={product.ratings != null && product.ratings.count > 0}
            seller={product.seller}
          />
        ) : null}
      </section>
    </article>
  );
};

const Covers = ({
  covers,
  mainCoverId,
  productName,
}: {
  covers: AssetPreview[];
  mainCoverId: string | null;
  productName: string;
}) => {
  const [activeCoverId, setActiveCoverId] = React.useState(mainCoverId);
  useOnChange(() => setActiveCoverId(mainCoverId), [mainCoverId]);

  if (covers.length === 0) return null;

  return (
    <CoversComponent
      covers={covers}
      activeCoverId={activeCoverId}
      setActiveCoverId={setActiveCoverId}
      productName={productName}
      className={classNames("[grid-area:covers]", !activeCoverId && "pb-[25%]")}
    />
  );
};

const ExistingPurchaseCard = ({
  permalink,
  isPreorder,
  isBundle,
  customViewContentButtonText,
  purchase,
}: {
  permalink: string;
  isPreorder: boolean;
  isBundle: boolean;
  customViewContentButtonText: string | null;
  purchase: Purchase;
}) => {
  const handleViewClick = () =>
    void trackUserProductAction({
      name: "product_information_view_product",
      permalink,
    }).catch(assertResponseError);

  const viewContentButton = purchase.show_view_content_button_on_product_page ? (
    <NavigationButton color="primary" href={purchase.content_url ?? ""} target="_blank" onClick={handleViewClick}>
      {customViewContentButtonText ?? "View content"}
    </NavigationButton>
  ) : null;

  const allowRating = differenceInYears(new Date(), parseISO(purchase.created_at)) < 1;

  if (!purchase.should_show_receipt) return null;

  return (
    <section className="border-t border-border p-6">
      <Card>
        {purchase.membership ? (
          <>
            <CardContent>
              <h5 className="grow font-bold">{purchase.membership.tier_name}</h5>
              {purchase.total_price_including_tax_and_shipping}
            </CardContent>
            <CardContent>
              <NavigationButton
                href={purchase.membership.manage_url}
                target="_blank"
                onClick={() =>
                  void trackUserProductAction({
                    name: "product_information_manage_membership",
                    permalink,
                  }).catch(assertResponseError)
                }
                className="grow basis-0"
              >
                {purchase.subscription_has_lapsed ? "Restart membership" : "Manage membership"}
              </NavigationButton>
              {viewContentButton}
            </CardContent>
          </>
        ) : (
          <CardContent asChild>
            <li>
              <h3 className="grow">
                {isBundle
                  ? purchase.is_gift_receiver_purchase
                    ? "You've received this bundle as a gift"
                    : purchase.was_paid
                      ? "You've purchased this bundle"
                      : "You already own this bundle"
                  : purchase.is_gift_receiver_purchase
                    ? "You've received this product as a gift"
                    : purchase.was_paid
                      ? "You've purchased this product"
                      : "You already own this product"}
              </h3>
              {viewContentButton}
            </li>
          </CardContent>
        )}
        {purchase.license_key ? <LicenseKeyRow licenseKey={purchase.license_key} /> : null}
        {!isPreorder && allowRating ? (
          <ReviewForm
            permalink={permalink}
            purchaseId={purchase.id}
            review={purchase.review}
            accountName={purchase.review_account_name}
            purchaseEmailDigest={purchase.email_digest}
            className="flex flex-wrap items-center justify-between gap-4 p-4"
          />
        ) : null}
      </Card>
    </section>
  );
};

// Shows the buyer's license key inline in the "you already own this" card so a returning
// buyer does not have to open the content page (or email the seller) to find it. Only
// rendered when the backend included the key, which it does only for identified visitors.
const LicenseKeyRow = ({ licenseKey }: { licenseKey: string }) => (
  <CardContent>
    <div className="grid grow gap-1">
      <h5 className="font-bold">License key</h5>
      <div className="break-all">{licenseKey}</div>
    </div>
    <CopyToClipboard text={licenseKey}>
      <Button>Copy</Button>
    </CopyToClipboard>
  </CardContent>
);

const PurchaseRecoveryLink = ({
  permalink,
  isLicensed,
  hasDownload,
  disableAnalytics,
}: {
  permalink: string;
  isLicensed: boolean;
  hasDownload: boolean;
  disableAnalytics: boolean | undefined;
}) => {
  // The lookup route only exists on the root domain, including for products on custom domains.
  const { scheme, rootDomain } = useDomains();

  return (
    <p className="text-center text-sm">
      Already bought this?{" "}
      <a
        href={Routes.license_key_lookup_url({ protocol: scheme, host: rootDomain })}
        className="relative inline-block underline after:absolute after:inset-x-0 after:top-1/2 after:h-10 after:-translate-y-1/2"
        onClick={() => {
          if (!disableAnalytics)
            trackUserProductAction({ name: "product_purchase_recovery_click", permalink, keepalive: true }).catch(
              assertResponseError,
            );
        }}
      >
        {isLicensed ? "View your information" : hasDownload ? "Get your download link" : "Resend your receipt"}
      </a>
    </p>
  );
};

export const RatingsHistogramRow = ({ rating, percentage }: { rating: number; percentage: number }) => {
  const formattedPercentage = `${percentage}%`;
  const label = `${rating} ${rating === 1 ? "star" : "stars"}`;
  return (
    <>
      <div>{label}</div>
      <meter
        aria-label={label}
        value={percentage / 100}
        className="h-[1lh] w-full appearance-none rounded border border-border bg-none [&::-moz-meter-bar]:rounded [&::-moz-meter-bar]:[background:var(--color-accent)] [&::-webkit-meter-bar]:contents [&::-webkit-meter-inner-element]:contents [&::-webkit-meter-optimum-value]:rounded [&::-webkit-meter-optimum-value]:[background:var(--color-accent)]"
      />
      <div>{formattedPercentage}</div>
    </>
  );
};

const Reviews = ({
  productId,
  ratings,
  seller,
}: {
  productId: string;
  ratings: RatingsWithPercentages;
  seller: Seller | null;
}) => {
  const loggedInUser = useLoggedInUser();
  const [state, setState] = React.useState<{ reviews: Review[]; pagination: PaginationProps }>({
    reviews: [],
    pagination: { page: 0, pages: 1 },
  });
  const [isLoading, setIsLoading] = React.useState(false);
  const loadNextPage = async () => {
    if (ratings.count === 0) return;
    setIsLoading(true);
    try {
      const { reviews, pagination } = await getReviews(productId, state.pagination.page + 1);
      setState(({ reviews: prevReviews }) => ({ pagination, reviews: [...prevReviews, ...reviews] }));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };
  useRunOnce(() => void loadNextPage());

  if (ratings.count === 0) return null;

  return (
    <section className="grid gap-4 p-6 not-first:border-t">
      <header className="flex items-center justify-between">
        <h3>Ratings</h3>
        <div className="flex shrink-0 items-center gap-1">
          <Star pack="filled" className="size-5" />
          <div className="rating-average">{ratings.average}</div>(
          {`${formatOrderOfMagnitude(ratings.count, 1)} ${ratings.count === 1 ? "rating" : "ratings"}`})
        </div>
      </header>
      {/* Rating markup lives in the page's JSON-LD (Product::StructuredData), where the
          AggregateRating nests under the Product. Do not re-add microdata here: this section
          has no itemscope Product ancestor, so an itemscope block becomes a standalone
          top-level AggregateRating that Google's Rich Results Test flags as
          "Missing field itemReviewed" (gumroad-private#1875). */}
      <section className="grid grid-cols-[auto_1fr_auto] gap-3" aria-label="Ratings histogram">
        {([4, 3, 2, 1, 0] as const).map((rating) => (
          <RatingsHistogramRow rating={rating + 1} percentage={ratings.percentages[rating]} key={rating} />
        ))}
      </section>
      {state.reviews.length ? (
        <section className="flex flex-col gap-4" style={{ marginTop: "var(--spacer-2)" }}>
          {state.reviews.map((review, idx) => (
            <Review
              key={review.id}
              review={review}
              seller={seller}
              isLast={idx === state.reviews.length - 1}
              canRespond={seller?.id === loggedInUser?.id}
            />
          ))}
          {state.pagination.page < state.pagination.pages ? (
            <LinkButton onClick={() => void loadNextPage()} disabled={isLoading}>
              Load more
            </LinkButton>
          ) : null}
        </section>
      ) : null}
    </section>
  );
};

const Review = ({
  review,
  seller,
  isLast,
  canRespond,
}: {
  review: Review;
  seller: Seller | null;
  isLast: boolean;
  canRespond: boolean;
}) => (
  <>
    <ReviewComponent review={review} seller={seller} canRespond={canRespond} />
    {isLast ? null : <hr />}
  </>
);

// Labelled creator context, never the product's own rating: the two copy
// states keep an unreviewed product visibly unreviewed, and the count links
// through to the seller's profile so the aggregate's composition is inspectable.
const SellerReputationSection = ({
  reputation,
  hasOwnReviews,
  seller,
}: {
  reputation: SellerReputation;
  hasOwnReviews: boolean;
  seller: Seller | null;
}) => (
  <section className="grid gap-2 p-6 not-first:border-t" aria-label="Creator rating">
    {!hasOwnReviews ? <div>This product has no reviews yet.</div> : null}
    <div className="flex flex-wrap items-center gap-1">
      <RatingStars rating={reputation.average} />
      <span>
        Creator rating: {reputation.average} from{" "}
        {seller ? (
          <a href={seller.profile_url}>
            {reputation.count} verified {reputation.count === 1 ? "review" : "reviews"}
          </a>
        ) : (
          `${reputation.count} verified ${reputation.count === 1 ? "review" : "reviews"}`
        )}{" "}
        across {reputation.products_count} other products.
      </span>
    </div>
  </section>
);

export const RatingsSummary = ({ ratings, className }: { ratings: Ratings; className?: string }) => (
  <div className={classNames("flex shrink-0 items-center", className)}>
    <RatingStars rating={ratings.average} />
    <span className="rating-number ml-1">
      {ratings.count} {ratings.count === 1 ? "rating" : "ratings"}
    </span>
  </div>
);

const RefundPolicyInfo = ({ refundPolicy, permalink }: { refundPolicy: RefundPolicy; permalink: string }) => {
  const HASH = "#refund-policy";
  const [viewingRefundPolicy, setViewingRefundPolicy] = React.useState(false);
  const userAgentInfo = useUserAgentInfo();

  useRunOnce(() => {
    setViewingRefundPolicy(window.location.hash === HASH);
  });

  React.useEffect(() => {
    if (viewingRefundPolicy) {
      void trackUserProductAction({
        name: "product_refund_policy_fine_print_view",
        permalink,
        isModal: true,
      });
    }
  }, [viewingRefundPolicy]);

  const formattedDate = parseISO(refundPolicy.updated_at).toLocaleString(userAgentInfo.locale, { dateStyle: "medium" });
  const lastUpdated = `Last updated ${formattedDate}`;

  const handleCloseModal = () => {
    setViewingRefundPolicy(false);
    window.history.replaceState(window.history.state, "", window.location.href.split("#")[0]);
  };
  return (
    <>
      <div className="text-center">
        {refundPolicy.fine_print ? (
          <a href={HASH} onClick={() => setViewingRefundPolicy(true)}>
            {refundPolicy.title}
          </a>
        ) : (
          refundPolicy.title
        )}
      </div>
      {refundPolicy.fine_print ? (
        <Modal
          open={viewingRefundPolicy}
          onClose={handleCloseModal}
          title={refundPolicy.title}
          footer={<p>{lastUpdated}</p>}
        >
          <div className="flex flex-col gap-4">
            <div
              dangerouslySetInnerHTML={{
                __html: refundPolicy.fine_print,
              }}
              style={{ display: "contents" }}
            ></div>
          </div>
        </Modal>
      ) : null}
    </>
  );
};
