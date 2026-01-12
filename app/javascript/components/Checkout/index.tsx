import * as React from "react";

import { computeOfferDiscount } from "$app/data/offer_code";
import { getRecommendedProducts } from "$app/data/recommended_products";
import { CardProduct, COMMISSION_DEPOSIT_PROPORTION } from "$app/parsers/product";
import { isOpenTuple } from "$app/utils/array";
import { classNames } from "$app/utils/classNames";
import { formatUSDCentsWithExpandedCurrencySymbol } from "$app/utils/currency";
import { formatCallDate } from "$app/utils/date";
import { variantLabel } from "$app/utils/labels";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { formatAmountPerRecurrence, recurrenceNames, recurrenceDurationLabels } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import {
  CartItem,
  CartItemFooter,
  CartItemMain,
  CartItemMedia,
  CartItemTitle,
  CartItemList,
  CartItemEnd,
  CartItemQuantity,
  CartItemActions,
} from "$app/components/CartItemList";
import { GiftForm } from "$app/components/Checkout/GiftForm";
import { PaymentForm } from "$app/components/Checkout/PaymentForm";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Card } from "$app/components/Product/Card";
import {
  applySelection,
  ConfigurationSelector,
  PriceSelection,
  computeDiscountedPrice,
} from "$app/components/Product/ConfigurationSelector";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

import {
  CartState,
  convertToUSD,
  hasFreeTrial,
  getDiscountedPrice,
  CartItem as CartItemProps,
  findCartItem,
} from "./cartState";
import { computeTip, computeTipForPrice, getTotalPrice, isProcessing, useState } from "./payment";

import placeholder from "$assets/images/placeholders/checkout.png";

function formatPrice(price: number) {
  return formatUSDCentsWithExpandedCurrencySymbol(Math.floor(price));
}

const nameOfSalesTaxForCountry = (countryCode: string) => {
  switch (countryCode) {
    case "US":
      return "Sales tax";
    case "CA":
      return "Tax";
    case "AU":
    case "IN":
    case "NZ":
    case "SG":
      return "GST";
    case "MY":
      return "Service tax";
    case "JP":
      return "CT";
    default:
      return "VAT";
  }
};

export const Checkout = ({
  discoverUrl,
  cart,
  setCart,
  recommendedProducts,
  setRecommendedProducts,
}: {
  discoverUrl: string;
  cart: CartState;
  setCart?: (prev: React.SetStateAction<CartState>) => void;
  recommendedProducts?: CardProduct[] | null;
  setRecommendedProducts?: (prev: React.SetStateAction<CardProduct[] | null>) => void;
}) => {
  const [state] = useState();
  const [newDiscountCode, setNewDiscountCode] = React.useState("");
  const [loadingDiscount, setLoadingDiscount] = React.useState(false);

  const updateCart = (updated: Partial<CartState>) => setCart?.((prevCart) => ({ ...prevCart, ...updated }));
  const isGift = state.gift != null;

  async function applyDiscount(code: string, fromUrl = false) {
    setLoadingDiscount(true);
    const discount = await computeOfferDiscount({
      code,
      products: Object.fromEntries(
        cart.items.map((item) => [
          item.product.permalink,
          { permalink: item.product.permalink, quantity: item.quantity },
        ]),
      ),
    });
    if (discount.valid) {
      const entries = Object.entries(discount.products_data);
      const pppDiscountGreaterCount = entries.reduce((acc, [permalink, discount]) => {
        const item = cart.items.find(({ product }) => product.permalink === permalink);
        return item && computeDiscountedPrice(item.price, discount, item.product).ppp ? acc + 1 : acc;
      }, 0);
      if (pppDiscountGreaterCount === entries.length) {
        showAlert(
          "The offer code will not be applied because the purchasing power parity discount is greater than the offer code discount for all products.",
          "error",
        );
      } else {
        if (pppDiscountGreaterCount > 0)
          showAlert(
            "The offer code will not be applied to some products for which the purchasing power parity discount is greater than the offer code discount.",
            "warning",
          );
        updateCart({
          discountCodes: [
            { code, products: discount.products_data, fromUrl },
            ...cart.discountCodes
              .map((item) => ({
                ...item,
                products: Object.fromEntries(
                  Object.entries(item.products).filter(([permalink]) => !(permalink in discount.products_data)),
                ),
              }))
              .filter((item) => item.code !== code && Object.keys(item.products).length > 0),
          ],
        });
      }
      setNewDiscountCode("");
    } else {
      showAlert(discount.error_message, "error");
    }

    setLoadingDiscount(false);
  }

  const hasAddedProduct = !!new URL(useOriginalLocation()).searchParams.get("product");
  useRunOnce(() => {
    const url = new URL(window.location.href);
    const code = url.searchParams.get("code");
    if (hasAddedProduct) cart.discountCodes.forEach(({ code }) => void applyDiscount(code));
    if (code) {
      void applyDiscount(code, true);
      url.searchParams.delete("code");
      window.history.replaceState(window.history.state, "", url.toString());
    }
  });

  const discount = cart.items.reduce(
    (sum, item) =>
      sum +
      convertToUSD(
        item,
        hasFreeTrial(item, isGift) ? 0 : item.price * item.quantity - getDiscountedPrice(cart, item).price,
      ),
    0,
  );

  const discountInputDisabled = loadingDiscount || isProcessing(state);
  const subtotal = cart.items.reduce(
    (sum, item) => sum + Math.round(hasFreeTrial(item, isGift) ? 0 : convertToUSD(item, item.price) * item.quantity),
    0,
  );

  const total = getTotalPrice(state);
  const visibleDiscounts = cart.discountCodes.filter(
    (code) =>
      !code.fromUrl ||
      Object.values(code.products).some((discount) =>
        discount.type === "fixed" ? discount.cents > 0 : discount.percents > 0,
      ),
  );

  const isMobile = !useIsAboveBreakpoint("sm");
  const productIds = cart.items.map(({ product }) => product.id);
  React.useEffect(() => {
    if (state.status.type !== "input") return;
    if (!productIds.length) return;
    asyncVoid(async () => {
      try {
        setRecommendedProducts?.(await getRecommendedProducts(productIds, isMobile ? 2 : 6));
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    })();
  }, [isMobile, productIds.join(",")]);

  const tip = computeTip(state);
  const commissionTotal = cart.items
    .filter((item) => item.product.native_type === "commission")
    .reduce((sum, item) => sum + getDiscountedPrice(cart, item).price, 0);
  const commissionCompletionTotal =
    (commissionTotal + (computeTipForPrice(state, commissionTotal) ?? 0)) * (1 - COMMISSION_DEPOSIT_PROPORTION);

  // The full tip amount is charged upfront for installment plans.
  const futureInstallmentsWithoutTipsTotal = cart.items.reduce((sum, item) => {
    if (!item.product.installment_plan || !item.pay_in_installments) return sum;

    const price = convertToUSD(item, getDiscountedPrice(cart, item).price);
    const firstInstallmentPrice = calculateFirstInstallmentPaymentPriceCents(
      price,
      item.product.installment_plan.number_of_installments,
    );
    return sum + (price - firstInstallmentPrice);
  }, 0);

  const isDesktop = useIsAboveBreakpoint("lg");

  return (
    <div className="mx-auto w-full max-w-product-page">
      <PageHeader
        className="border-none"
        title="Checkout"
        actions={
          isDesktop ? <NavigationButton href={cart.returnUrl ?? discoverUrl}>Continue shopping</NavigationButton> : null
        }
      />
      {isOpenTuple(cart.items, 1) ? (
        <div className="grid gap-8 p-4 md:p-8">
          <div className="grid grid-cols-1 items-start gap-x-16 gap-y-8 lg:grid-cols-[2fr_minmax(26rem,1fr)]">
            <div className="grid gap-6">
              <CartItemList>
                {cart.items.map((item) => (
                  <CartItemComponent
                    key={`${item.product.permalink}${item.option_id ? `_${item.option_id}` : ""}`}
                    item={item}
                    cart={cart}
                    isGift={isGift}
                    updateCart={updateCart}
                  />
                ))}
                {state.products.length === 1 && state.products[0]?.canGift && !state.products[0]?.payInInstallments ? (
                  <div className="border-t border-border p-4">
                    <GiftForm isMembership={state.products[0]?.nativeType === "membership"} />
                  </div>
                ) : null}
              </CartItemList>
              <CartItemList>
                <div className="grid gap-4 border-border p-4">
                  {state.surcharges.type === "loaded" ? (
                    <>
                      <CartPriceItem title="Subtotal" price={formatPrice(subtotal)} />
                      {tip ? <CartPriceItem title="Tip" price={formatPrice(tip)} /> : null}
                      {state.surcharges.result.tax_included_cents ? (
                        <CartPriceItem
                          title={`${nameOfSalesTaxForCountry(state.country)} (included)`}
                          price={formatPrice(state.surcharges.result.tax_included_cents)}
                        />
                      ) : null}
                      {state.surcharges.result.tax_cents ? (
                        <CartPriceItem
                          title={nameOfSalesTaxForCountry(state.country)}
                          price={formatPrice(state.surcharges.result.tax_cents)}
                        />
                      ) : null}
                      {state.surcharges.result.shipping_rate_cents ? (
                        <CartPriceItem
                          title="Shipping rate"
                          price={formatPrice(state.surcharges.result.shipping_rate_cents)}
                        />
                      ) : null}
                    </>
                  ) : null}
                  {visibleDiscounts.length || discount > 0 ? (
                    <div className="grid grid-flow-col justify-between gap-4">
                      <h4 className="inline-flex flex-wrap gap-2">
                        Discounts
                        {cart.items.some((item) => !!item.product.ppp_details && item.price !== 0) &&
                        !cart.rejectPppDiscount ? (
                          <WithTooltip
                            tip="This discount is applied based on the cost of living in your country."
                            position="top"
                          >
                            <Pill asChild size="small" className="cursor-pointer">
                              <button
                                onClick={() => updateCart({ rejectPppDiscount: true })}
                                aria-label="Purchasing power parity discount"
                              >
                                Purchasing power parity discount
                                <Icon name="x" className="ml-2" />
                              </button>
                            </Pill>
                          </WithTooltip>
                        ) : null}
                        {visibleDiscounts.map((code) => (
                          <Pill
                            size="small"
                            className="cursor-pointer"
                            onClick={() =>
                              updateCart({ discountCodes: cart.discountCodes.filter((item) => item !== code) })
                            }
                            key={code.code}
                            aria-label="Discount code"
                          >
                            {code.code}
                            <Icon name="x" className="ml-2" />
                          </Pill>
                        ))}
                      </h4>
                      {discount > 0 ? <div>{formatPrice(-discount)}</div> : null}
                    </div>
                  ) : null}
                  {cart.items.some((item) => item.product.has_offer_codes) ? (
                    <form
                      className="flex! gap-2"
                      onSubmit={(e) => {
                        e.preventDefault();
                        void applyDiscount(newDiscountCode);
                      }}
                    >
                      <input
                        placeholder="Discount code"
                        value={newDiscountCode}
                        className="flex-1"
                        disabled={discountInputDisabled}
                        onChange={(e) => setNewDiscountCode(e.target.value)}
                      />
                      <Button type="submit" disabled={discountInputDisabled}>
                        Apply
                      </Button>
                    </form>
                  ) : null}
                </div>
                {total != null ? (
                  <>
                    <footer className="grid gap-4 border-t border-border p-4">
                      <CartPriceItem title="Total" price={formatPrice(total)} large />
                    </footer>
                    {commissionCompletionTotal > 0 || futureInstallmentsWithoutTipsTotal > 0 ? (
                      <div className="grid gap-4 border-t border-border p-4">
                        <CartPriceItem
                          title="Payment today"
                          price={formatPrice(total - commissionCompletionTotal - futureInstallmentsWithoutTipsTotal)}
                        />
                        {commissionCompletionTotal > 0 ? (
                          <CartPriceItem
                            title="Payment after completion"
                            price={formatPrice(commissionCompletionTotal)}
                          />
                        ) : null}
                        {futureInstallmentsWithoutTipsTotal > 0 ? (
                          <CartPriceItem
                            title="Future installments"
                            price={formatPrice(futureInstallmentsWithoutTipsTotal)}
                          />
                        ) : null}
                      </div>
                    ) : null}
                  </>
                ) : null}
              </CartItemList>
              {recommendedProducts && recommendedProducts.length > 0 ? (
                <section className="flex flex-col gap-4">
                  <h2>Customers who bought {cart.items.length === 1 ? "this item" : "these items"} also bought</h2>
                  <ProductCardGrid narrow>
                    {recommendedProducts.map((product, idx) => (
                      // All of this grid is off-screen. so we just eager load the first image
                      <Card key={product.id} product={product} eager={idx === 0} />
                    ))}
                  </ProductCardGrid>
                </section>
              ) : null}
            </div>
            <PaymentForm />
            {!isDesktop && <NavigationButton href={cart.returnUrl ?? discoverUrl}>Continue shopping</NavigationButton>}
          </div>
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h3>You haven't added anything...yet!</h3>
            <p>Once you do, it'll show up here so you can complete your purchases.</p>
            <a className="button accent" href={discoverUrl}>
              Discover products
            </a>
          </Placeholder>
        </div>
      )}
    </div>
  );
};

const CartPriceItem = ({
  title,
  price,
  large = false,
}: {
  title: React.ReactNode;
  price: string | number | null;
  large?: boolean;
}) => (
  <div className={classNames("grid grid-flow-col justify-between gap-4")}>
    <h4
      className={classNames(
        "inline-flex flex-wrap gap-2",
        large ? "text-base font-bold sm:text-xl" : "text-sm sm:text-base",
      )}
    >
      {title}
    </h4>
    <div className={classNames("text-base sm:text-lg", large && "font-bold")}>{price}</div>
  </div>
);

const CartItemComponent = ({
  item,
  cart,
  updateCart,
  isGift,
}: {
  item: CartItemProps;
  cart: CartState;
  updateCart: (update: Partial<CartState>) => void;
  isGift: boolean;
}) => {
  const [editPopoverOpen, setEditPopoverOpen] = React.useState(false);
  const [selection, setSelection] = React.useState<PriceSelection>({
    rent: item.rent,
    optionId: item.option_id,
    price: { value: item.price, error: false },
    quantity: item.quantity,
    recurrence: item.recurrence,
    callStartTime: item.call_start_time,
    payInInstallments: item.pay_in_installments,
  });
  const [error, setError] = React.useState<null | string>(null);

  const discount = getDiscountedPrice(cart, item);

  const { priceCents, isPWYW } = applySelection(
    item.product,
    discount.discount && discount.discount.type !== "ppp" ? discount.discount.value : null,
    selection,
  );

  const saveChanges = () => {
    if (isPWYW && (selection.price.value === null || selection.price.value < priceCents))
      return setSelection({ ...selection, price: { ...selection.price, error: true } });
    if (selection.optionId !== item.option_id && findCartItem(cart, item.product.permalink, selection.optionId))
      return setError("You already have this item in your cart.");
    const index = cart.items.findIndex((i) => i === item);
    const items = cart.items.slice();
    items[index] = {
      ...item,
      price: isPWYW ? (selection.price.value ?? priceCents) : priceCents,
      option_id: selection.optionId,
      recurrence: selection.recurrence,
      rent: selection.rent,
      quantity: selection.quantity,
      call_start_time: selection.callStartTime,
      pay_in_installments: selection.payInInstallments,
    };
    updateCart({ items });
    setEditPopoverOpen(false);
  };

  const option = item.product.options.find((option) => option.id === item.option_id);
  const price = hasFreeTrial(item, isGift) ? 0 : item.price * item.quantity;

  return (
    <CartItem
      extra={
        item.product.bundle_products.length > 0 ? (
          <div className="flex flex-col gap-3">
            <h4>This bundle contains...</h4>
            <CartItemList className="overflow-hidden">
              {item.product.bundle_products.map((bundleProduct) => (
                <CartItem key={bundleProduct.product_id} isBundleItem>
                  <CartItemMedia className="h-20 w-20">
                    <a href={bundleProduct.url}>
                      <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
                    </a>
                  </CartItemMedia>
                  <span className="sr-only">Qty: {bundleProduct.quantity || item.quantity}</span>
                  <CartItemMain className="h-20">
                    <CartItemTitle className="line-clamp-1">{bundleProduct.name}</CartItemTitle>
                    {bundleProduct.variant ? (
                      <CartItemFooter className="line-clamp-1">
                        <span>
                          <strong>{variantLabel(bundleProduct.native_type)}:</strong> {bundleProduct.variant.name}
                        </span>
                      </CartItemFooter>
                    ) : null}
                  </CartItemMain>
                </CartItem>
              ))}
            </CartItemList>
          </div>
        ) : null
      }
    >
      <div className="relative inline-flex">
        <CartItemMedia className="h-16 w-16 sm:h-30 sm:w-30">
          <a href={item.product.url}>
            <Thumbnail url={item.product.thumbnail_url} nativeType={item.product.native_type} />
          </a>
        </CartItemMedia>
        <CartItemQuantity>{item.quantity}</CartItemQuantity>
      </div>

      <CartItemMain>
        <CartItemTitle>
          <a href={item.product.url} className="no-underline">
            {item.product.name}
          </a>
        </CartItemTitle>
        <a href={item.product.creator.profile_url} className="line-clamp-2 text-sm">
          {item.product.creator.name}
        </a>
        <CartItemFooter>
          {option?.name ? (
            <span>
              <strong>{variantLabel(item.product.native_type)}:</strong> {option.name}
            </span>
          ) : null}
          {item.call_start_time ? (
            <span>
              <strong>Time:</strong> {formatCallDate(new Date(item.call_start_time), { date: { hideYear: true } })}
            </span>
          ) : null}
          <CartItemActions>
            {(item.product.rental && !item.product.rental.rent_only) ||
            item.product.is_quantity_enabled ||
            item.product.recurrences ||
            item.product.options.length > 0 ||
            item.product.installment_plan ||
            isPWYW ? (
              <Popover
                trigger={<Button className="h-8 w-15 !p-0 !text-xs">Edit</Button>}
                open={editPopoverOpen}
                onToggle={setEditPopoverOpen}
              >
                <div className="flex w-96 flex-col gap-4">
                  <ConfigurationSelector
                    selection={selection}
                    setSelection={(selection) => {
                      setError(null);
                      setSelection(selection);
                    }}
                    product={item.product}
                    discount={discount.discount && discount.discount.type !== "ppp" ? discount.discount.value : null}
                    showInstallmentPlan
                  />
                  {error ? <Alert variant="danger">{error}</Alert> : null}
                  <Button color="accent" onClick={saveChanges}>
                    Save changes
                  </Button>
                </div>
              </Popover>
            ) : null}
            <Button
              className="h-8 w-15 !p-0 !text-xs"
              onClick={() => {
                const newItems = cart.items.filter((i) => i !== item);
                updateCart({
                  discountCodes: cart.discountCodes.filter(({ products }) =>
                    Object.keys(products).some((permalink) =>
                      newItems.some((item) => item.product.permalink === permalink),
                    ),
                  ),
                  items: newItems.map(({ accepted_offer, ...rest }) => ({
                    ...rest,
                    accepted_offer:
                      accepted_offer?.original_product_id === item.product.id ? null : (accepted_offer ?? null),
                  })),
                });
              }}
            >
              Remove
            </Button>
          </CartItemActions>
        </CartItemFooter>
      </CartItemMain>
      <CartItemEnd>
        <span className="current-price text-base font-bold sm:text-lg" aria-label="Price">
          {formatPrice(convertToUSD(item, price))}
        </span>
        {hasFreeTrial(item, isGift) && item.product.free_trial ? (
          <>
            <span className="text-sm">
              {item.product.free_trial.duration.amount === 1
                ? `one ${item.product.free_trial.duration.unit}`
                : `${item.product.free_trial.duration.amount} ${item.product.free_trial.duration.unit}s`}{" "}
              free
            </span>
            {item.recurrence ? (
              <span className="text-sm">
                {formatAmountPerRecurrence(item.recurrence, formatPrice(convertToUSD(item, discount.price)))} after
              </span>
            ) : null}
          </>
        ) : item.pay_in_installments && item.product.installment_plan ? (
          <span className="text-sm">in {item.product.installment_plan.number_of_installments} installments</span>
        ) : item.recurrence ? (
          isGift ? (
            <span className="text-sm">{recurrenceDurationLabels[item.recurrence]}</span>
          ) : (
            <span className="text-sm">{recurrenceNames[item.recurrence]}</span>
          )
        ) : null}
      </CartItemEnd>
    </CartItem>
  );
};
