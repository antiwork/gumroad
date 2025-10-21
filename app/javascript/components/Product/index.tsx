import { EditorContent } from "@tiptap/react";
import { differenceInYears, parseISO } from "date-fns";
import * as React from "react";

import { getReviews, Review } from "$app/data/product_reviews";
import { trackUserProductAction } from "$app/data/user_action_event";
import { incrementProductViews } from "$app/data/view_event";
import { Wishlist } from "$app/data/wishlists";
import { Discount } from "$app/parsers/checkout";
import {
  AnalyticsData,
  AssetPreview,
  COMMISSION_DEPOSIT_PROPORTION,
  CustomButtonTextOption,
  FreeTrial,
  ProductNativeType,
  Ratings,
  RatingsWithPercentages,
} from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { formatDate } from "$app/utils/date";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";
import { variantLabel } from "$app/utils/labels";
import { assertResponseError } from "$app/utils/request";
import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

import { NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { PaginationProps } from "$app/components/Pagination";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import {
  Option,
  ConfigurationSelector,
  Rental,
  Recurrences,
  PriceSelection,
  applySelection,
  PurchasingPowerParityDetails,
  ConfigurationSelectorHandle,
  getMaxQuantity,
} from "$app/components/Product/ConfigurationSelector";
import { Covers as CoversComponent } from "$app/components/Product/Covers";
import { CtaButton } from "$app/components/Product/CtaButton";
import { DiscountExpirationCountdown } from "$app/components/Product/DiscountExpirationCountdown";
import { PriceTag } from "$app/components/Product/PriceTag";
import { ShareSection } from "$app/components/Product/ShareSection";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { PublicFilesSettingsContext } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { InstallmentPlan } from "$app/components/ProductEdit/state";
import { RatingStars } from "$app/components/RatingStars";
import { Review as ReviewComponent } from "$app/components/Review";
import { ReviewForm, Review as FormReview } from "$app/components/ReviewForm";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { PublicFileEmbed } from "$app/components/TiptapExtensions/PublicFileEmbed";
import { ReviewCard } from "$app/components/TiptapExtensions/ReviewCard";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useOnChange } from "$app/components/useOnChange";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

export type Seller = { id: string; name: string; avatar_url: string; profile_url: string };

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
  pwyw: { suggested_price_cents: number | null } | null;
  installment_plan: InstallmentPlan | null;
  ratings: RatingsWithPercentages | null;
  is_legacy_subscription: boolean;
  is_tiered_membership: boolean;
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
  audio_previews_enabled: boolean;
};
export type Purchase = {
  id: string;
  email_digest: string;
  created_at: string;
  review: FormReview | null;
  should_show_receipt: boolean;
  is_gift_receiver_purchase: boolean;
  content_url: string | null;
  show_view_content_button_on_product_page: boolean;
  total_price_including_tax_and_shipping: string;
  subscription_has_lapsed: boolean;
  membership: { tier_name: string | null; tier_description: string | null; manage_url: string } | null;
};
export type ProductDiscount =
  | { valid: false; error_code: "sold_out" | "invalid_offer" | "inactive" | "unmet_minimum_purchase_quantity" }
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

export const getStandalonePrice = (product: Product) =>
  product.bundle_products.reduce(
    (totalStandalonePrice, bundleProduct) => totalStandalonePrice + bundleProduct.price,
    0,
  );

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
    const optionId =
      parsedOption && parsedOption.quantity_left !== 0
        ? parsedOption.id
        : (product.options.find(({ quantity_left }) => quantity_left !== 0)?.id ?? null);
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
      price: { value: parsedPrice >= 0 ? parsedPrice * 100 : null, error: false },
      callStartTime: isNaN(parsedCallStartTime.getTime()) ? null : parsedCallStartTime.toISOString(),
      payInInstallments: parsedPayInInstallments,
    };
  });
};

export type Props = {
  product: Product;
  purchase: Purchase | null;
  discount_code: ProductDiscount | null;
  wishlists: WishlistForProduct[];
};

export const Product = ({
  product,
  purchase,
  discountCode: initialDiscountCode,
  ctaLabel,
  selection,
  setSelection,
  ctaButtonRef,
  configurationSelectorRef,
  wishlists = [],
  disableAnalytics,
}: {
  product: Product;
  purchase: Purchase | null;
  discountCode?: ProductDiscount | null;
  ctaLabel?: string | undefined;
  selection: PriceSelection;
  setSelection?: React.Dispatch<React.SetStateAction<PriceSelection>>;
  ctaButtonRef?: React.MutableRefObject<HTMLAnchorElement | null>;
  configurationSelectorRef?: React.MutableRefObject<ConfigurationSelectorHandle | null>;
  wishlists?: WishlistForProduct[];
  disableAnalytics?: boolean;
}) => {
  const [pageLoaded, setPageLoaded] = React.useState(false);
  const descriptionEditor = useRichTextEditor({
    // delay initialization to avoid errors in SSR
    initialValue: pageLoaded ? product.description_html : null,
    extensions: [UpsellCard, PublicFileEmbed, ReviewCard],
    editable: false,
  });

  const notForSaleMessage = getNotForSaleMessage(product);
  const [discountCode, setDiscountCode] = React.useState(initialDiscountCode);
  const selectionAttributes = applySelection(product, discountCode?.valid ? discountCode.discount : null, selection);
  let { basePriceCents } = selectionAttributes;
  const { priceCents, discountedPriceCents, pppDiscounted, isPWYW, maxQuantity } = selectionAttributes;
  React.useEffect(() => {
    if (maxQuantity !== null && selection.quantity > maxQuantity)
      setSelection?.({ ...selection, quantity: maxQuantity });
  }, [maxQuantity, selection.quantity]);
  const publicFilesSettings = React.useMemo(
    () => ({
      files: product.public_files,
      audioPreviewsEnabled: product.audio_previews_enabled,
    }),
    [product.public_files],
  );

  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();

  const { searchParams } = new URL(useOriginalLocation());
  useRunOnce(() => {
    setPageLoaded(true);

    if (disableAnalytics) return;
    if (product.seller) {
      startTrackingForSeller(product.seller.id, product.analytics);
      trackProductEvent(product.seller.id, {
        permalink: product.permalink,
        action: "viewed",
        product_name: product.name,
      });
    }
    void incrementProductViews({ permalink: product.permalink, recommendedBy: searchParams.get("recommended_by") });
    if (product.has_third_party_analytics)
      addThirdPartyAnalytics({ permalink: product.permalink, location: "product" });
  });

  const isBundle = product.bundle_products.length > 0;
  if (isBundle) basePriceCents = getStandalonePrice(product);

  const validate = () => {
    if (isPWYW && (selection.price.value === null || selection.price.value < discountedPriceCents)) {
      setSelection?.({ ...selection, price: { ...selection.price, error: true } });
      if (selection.price.value === null) {
        configurationSelectorRef?.current?.focusRequiredInput();
        showAlert("You must input an amount", "warning");
      }
      return false;
    }
    if (product.native_type === "call" && !selection.callStartTime) {
      showAlert("You must select a date and time for the call", "warning");
      return false;
    }
    return true;
  };

  const sellerByline = product.seller ? (
    <AuthorByline
      name={product.seller.name}
      profileUrl={product.seller.profile_url}
      avatarUrl={product.seller.avatar_url}
    />
  ) : null;

  return (
    <article className="product">
      <Covers covers={product.covers} mainCoverId={product.main_cover_id} />
      {product.quantity_remaining !== null ? (
        <div className="ribbon">{`${product.quantity_remaining} left`}</div>
      ) : null}
      <section>
        <header>
          <h1 itemProp="name">{product.name}</h1>
        </header>
        <section className="details">
          {!product.recurrences &&
          product.options.length === 0 &&
          !product.rental?.rent_only &&
          (basePriceCents !== 0 || product.pwyw) ? (
            <PriceTag
              currencyCode={product.currency_code}
              oldPrice={discountedPriceCents < basePriceCents ? basePriceCents : undefined}
              price={discountedPriceCents}
              url={product.long_url}
              isPayWhatYouWant={!!product.pwyw}
              isSalesLimited={product.is_sales_limited}
              creatorName={product.seller?.name}
            />
          ) : null}
          {sellerByline ? (
            <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)", flexWrap: "wrap" }}>
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
          {product.ratings != null && product.ratings.count > 0 ? (
            <RatingsSummary className="max-sm:col-span-full" ratings={product.ratings} />
          ) : null}
        </section>
        {purchase !== null ? (
          <ExistingPurchaseStack
            purchase={purchase}
            permalink={product.permalink}
            isPreorder={product.preorder !== null}
            isBundle={isBundle}
            customViewContentButtonText={product.custom_view_content_button_text}
          />
        ) : null}
        {isBundle ? (
          <section>
            <h2>This bundle contains...</h2>
            <div className="cart" role="list">
              {product.bundle_products.map((bundleProduct) => {
                const price = formatPriceCentsWithCurrencySymbol(bundleProduct.currency_code, bundleProduct.price, {
                  symbolFormat: "long",
                });
                return (
                  <div role="listitem" key={bundleProduct.id}>
                    <section>
                      <figure>
                        <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
                      </figure>
                      <section>
                        <a href={bundleProduct.url}>
                          <h4>{bundleProduct.name}</h4>
                        </a>
                        {bundleProduct.ratings ? (
                          <section className="flex shrink-0 items-center gap-1" aria-label="Rating">
                            <Icon name="solid-star" />
                            {`${bundleProduct.ratings.average.toFixed(1)} (${bundleProduct.ratings.count})`}
                          </section>
                        ) : null}
                        <footer>
                          <ul>
                            <li>
                              <strong>Qty:</strong> {bundleProduct.quantity}
                            </li>
                            {bundleProduct.variant ? (
                              <li>
                                <strong>{variantLabel(bundleProduct.native_type)}:</strong> {bundleProduct.variant}
                              </li>
                            ) : null}
                          </ul>
                        </footer>
                      </section>
                      <section>
                        <span className="current-price" aria-label="Price">
                          {discountedPriceCents < basePriceCents ? <s>{price}</s> : price}
                        </span>
                      </section>
                    </section>
                  </div>
                );
              })}
            </div>
          </section>
        ) : null}
        <section>
          {pageLoaded ? (
            <PublicFilesSettingsContext.Provider value={publicFilesSettings}>
              <EditorContent className="rich-text" editor={descriptionEditor} />
            </PublicFilesSettingsContext.Provider>
          ) : (
            <div className="rich-text" dangerouslySetInnerHTML={{ __html: product.description_html ?? "" }} />
          )}
        </section>
      </section>
      <section>
        <section>
          {notForSaleMessage ? (
            <div role="status" className="warning">
              {notForSaleMessage}
            </div>
          ) : product.native_type === "commission" ? (
            <div role="status" className="info">
              Secure your order with a {`${COMMISSION_DEPOSIT_PROPORTION * 100}%`} deposit today; the remaining balance
              will be charged upon completion.
            </div>
          ) : null}
          {discountCode ? (
            discountCode.valid ? (
              (discountedPriceCents < priceCents || discountCode.discount.minimum_quantity) && !pppDiscounted ? (
                <div role="status" className="success">
                  <div className="paragraphs">
                    {discountCode.discount.minimum_quantity
                      ? `Get ${
                          discountCode.discount.type === "percent"
                            ? `${discountCode.discount.percents}%`
                            : formatPriceCentsWithCurrencySymbol(product.currency_code, discountCode.discount.cents, {
                                symbolFormat: "long",
                              })
                        } off when you buy ${discountCode.discount.minimum_quantity} or more (Code ${discountCode.code.toUpperCase()})`
                      : discountCode.discount.type === "percent"
                        ? `${discountCode.discount.percents}% off will be applied at checkout (Code ${discountCode.code.toUpperCase()})`
                        : `${formatPriceCentsWithCurrencySymbol(product.currency_code, discountCode.discount.cents, {
                            symbolFormat: "long",
                          })} off will be applied at checkout (Code ${discountCode.code.toUpperCase()})`}
                    {discountCode.discount.duration_in_billing_cycles && product.is_tiered_membership ? (
                      <div>This discount will only apply to the first payment of your subscription.</div>
                    ) : null}
                    {discountCode.discount.minimum_amount_cents ? (
                      <div>
                        {(discountCode.discount.product_ids?.length ?? 0) === 1
                          ? `This discount will apply when you spend ${formatPriceCentsWithCurrencySymbol(
                              product.currency_code,
                              discountCode.discount.minimum_amount_cents,
                              { symbolFormat: "short" },
                            )} or more.`
                          : `This discount will apply when you spend ${formatPriceCentsWithCurrencySymbol(
                              product.currency_code,
                              discountCode.discount.minimum_amount_cents,
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
                        onExpiration={() => setDiscountCode({ valid: false, error_code: "inactive" })}
                      />
                    ) : null}
                  </div>
                </div>
              ) : null
            ) : (
              <div role="status" className="danger">
                {discountCode.error_code === "sold_out"
                  ? "Sorry, the discount code you wish to use has expired."
                  : discountCode.error_code === "invalid_offer"
                    ? "Sorry, the discount code you wish to use is invalid."
                    : "Sorry, the discount code you wish to use is inactive."}
              </div>
            )
          ) : null}
          <ConfigurationSelector
            product={product}
            selection={selection}
            setSelection={setSelection}
            discount={discountCode?.valid ? discountCode.discount : null}
            ref={configurationSelectorRef}
          />
          {product.ppp_details && pppDiscounted ? (
            <div role="status" className="info">
              <div>
                This product supports purchasing power parity. Because you're located in{" "}
                <b>{product.ppp_details.country}</b>, the price has been discounted by{" "}
                <b>
                  {(Math.round((1 - discountedPriceCents / priceCents) * 100) / 100).toLocaleString(undefined, {
                    style: "percent",
                  })}
                </b>{" "}
                to{" "}
                <b>
                  {formatPriceCentsWithCurrencySymbol(product.currency_code, discountedPriceCents, {
                    symbolFormat: "long",
                  })}
                </b>
                .
                {discountCode?.valid
                  ? " This discount will be applied because it is greater than the offer code discount."
                  : null}
              </div>
            </div>
          ) : null}
          {product.free_trial ? (
            <div role="status" className="info">
              All memberships include a {product.free_trial.duration.amount} {product.free_trial.duration.unit} free
              trial
            </div>
          ) : null}
          {product.duration_in_months ? (
            <div role="status" className="info">
              This membership will automatically end after{" "}
              {product.duration_in_months === 1 ? "one month" : `${product.duration_in_months} months`}
            </div>
          ) : null}
          <CtaButton
            ref={ctaButtonRef}
            product={product}
            purchase={purchase}
            discountCode={discountCode ?? null}
            selection={selection}
            label={ctaLabel}
            showInstallmentPlanNotes
            onClick={(e) => {
              if (!validate()) e.preventDefault();
            }}
          />
          {product.sales_count !== null ? (
            <div role="status" className="info">
              <span>
                <strong>{product.sales_count.toLocaleString()}</strong>{" "}
                {product.recurrences
                  ? "member"
                  : product.preorder
                    ? "pre-order"
                    : product.price_cents > 0 || product.options.some((option) => option.price_difference_cents)
                      ? "sale"
                      : "download"}
                {product.sales_count === 1 ? "" : "s"}
              </span>
            </div>
          ) : null}
          {product.preorder ? (
            <div role="status" className="info">
              Available on {formatDate(parseISO(product.preorder.release_date))}
            </div>
          ) : null}
          {product.streamable ? (
            <div role="status" className="info">
              Watch link provided after purchase
            </div>
          ) : null}
          {product.summary || product.attributes.length > 0 ? (
            <div className="stack">
              {product.summary ? <p>{product.summary}</p> : null}
              {product.attributes.map(({ name, value }, idx) => (
                <div key={idx}>
                  <h5>{name}</h5>
                  <div>{value}</div>
                </div>
              ))}
            </div>
          ) : null}
          <ShareSection product={product} selection={selection} wishlists={wishlists} />
          {product.refund_policy ? (
            <RefundPolicyInfo refundPolicy={product.refund_policy} permalink={product.permalink} />
          ) : null}
        </section>
        {product.ratings ? <Reviews ratings={product.ratings} productId={product.id} seller={product.seller} /> : null}
      </section>
    </article>
  );
};

const Covers = ({ covers, mainCoverId }: { covers: AssetPreview[]; mainCoverId: string | null }) => {
  const [activeCoverId, setActiveCoverId] = React.useState(mainCoverId);
  useOnChange(() => setActiveCoverId(mainCoverId), [mainCoverId]);

  return (
    <CoversComponent
      covers={covers}
      activeCoverId={activeCoverId}
      setActiveCoverId={setActiveCoverId}
      className={activeCoverId ? "" : "pb-[25%]"}
    />
  );
};

const ExistingPurchaseStack = ({
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
    <section>
      <div className="stack">
        {purchase.membership ? (
          <>
            <div>
              <h5>{purchase.membership.tier_name}</h5>
              {purchase.total_price_including_tax_and_shipping}
            </div>
            <div>
              <NavigationButton
                href={purchase.membership.manage_url}
                target="_blank"
                onClick={() =>
                  void trackUserProductAction({
                    name: "product_information_manage_membership",
                    permalink,
                  }).catch(assertResponseError)
                }
              >
                {purchase.subscription_has_lapsed ? "Restart membership" : "Manage membership"}
              </NavigationButton>
              {viewContentButton}
            </div>
          </>
        ) : (
          <li>
            <h3>
              {isBundle
                ? purchase.is_gift_receiver_purchase
                  ? "You've received this bundle as a gift"
                  : "You've purchased this bundle"
                : purchase.is_gift_receiver_purchase
                  ? "You've received this product as a gift"
                  : "You've purchased this product"}
            </h3>
            {viewContentButton}
          </li>
        )}
        {!isPreorder && !isBundle && allowRating ? (
          <ReviewForm
            permalink={permalink}
            purchaseId={purchase.id}
            review={purchase.review}
            purchaseEmailDigest={purchase.email_digest}
          />
        ) : null}
      </div>
    </section>
  );
};

export const RatingsHistogramRow = ({ rating, percentage }: { rating: number; percentage: number }) => {
  const formattedPercentage = `${percentage}%`;
  const label = `${rating} ${rating === 1 ? "star" : "stars"}`;
  return (
    <>
      <div>{label}</div>
      <meter aria-label={label} value={percentage / 100} />
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
    <section>
      <header>
        <h3>Ratings</h3>
        <div className="flex shrink-0 items-center gap-1">
          <Icon name="solid-star" />
          <div className="rating-average">{ratings.average}</div>(
          {`${formatOrderOfMagnitude(ratings.count, 1)} ${ratings.count === 1 ? "rating" : "ratings"}`})
        </div>
      </header>
      <div itemProp="aggregateRating" itemType="https://schema.org/AggregateRating" itemScope hidden>
        <div itemProp="reviewCount">{ratings.count}</div>
        <div itemProp="ratingValue">{ratings.average}</div>
      </div>
      <section className="grid grid-cols-[auto_1fr_auto] gap-3" aria-label="Ratings histogram">
        {([4, 3, 2, 1, 0] as const).map((rating) => (
          <RatingsHistogramRow rating={rating + 1} percentage={ratings.percentages[rating]} key={rating} />
        ))}
      </section>
      {state.reviews.length ? (
        <section className="paragraphs" style={{ marginTop: "var(--spacer-2)" }}>
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
            <button className="underline" onClick={() => void loadNextPage()} disabled={isLoading}>
              Load more
            </button>
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

export const RatingsSummary = ({ ratings, className }: { ratings: Ratings; className?: string }) => (
  <div className={classNames("flex shrink-0 items-center gap-1", className)}>
    <RatingStars rating={ratings.average} />
    <span className="rating-number">
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

  const formattedDate = new Date(refundPolicy.updated_at).toLocaleString(userAgentInfo.locale, { dateStyle: "medium" });
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
          <div className="paragraphs">
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
