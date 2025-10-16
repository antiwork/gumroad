import * as React from "react";

import { computeOfferDiscount } from "$app/data/offer_code";
import { getRecommendedProducts } from "$app/data/recommended_products";
import { CardProduct, COMMISSION_DEPOSIT_PROPORTION } from "$app/parsers/product";
import { isOpenTuple } from "$app/utils/array";
import { formatUSDCentsWithExpandedCurrencySymbol } from "$app/utils/currency";
import { formatCallDate } from "$app/utils/date";
import { variantLabel } from "$app/utils/labels";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { formatAmountPerRecurrence, recurrenceNames, recurrenceDurationLabels } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { PaymentForm } from "$app/components/Checkout/PaymentForm";
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
import { PageHeader } from "$app/components/ui/PageHeader";
import Placeholder from "$app/components/ui/Placeholder";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

import { CartState, convertToUSD, hasFreeTrial, getDiscountedPrice, CartItem, findCartItem } from "./cartState";
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
              <div className="cart" role="list">
                {cart.items.map((item) => (
                  <CartItemComponent
                    key={`${item.product.permalink}${item.option_id ? `_${item.option_id}` : ""}`}
                    item={item}
                    cart={cart}
                    isGift={isGift}
                    updateCart={updateCart}
                  />
                ))}
                <div className="cart-summary">
                  {state.surcharges.type === "loaded" ? (
                    <>
                      <div>
                        <h4>Subtotal</h4>
                        <div>{formatPrice(subtotal)}</div>
                      </div>
                      {tip ? (
                        <div>
                          <h4>Tip</h4>
                          <div>{formatPrice(tip)}</div>
                        </div>
                      ) : null}
                      {state.surcharges.result.tax_included_cents ? (
                        <div>
                          <h4>{nameOfSalesTaxForCountry(state.country)} (included)</h4>
                          <div>{formatPrice(state.surcharges.result.tax_included_cents)}</div>
                        </div>
                      ) : null}
                      {state.surcharges.result.tax_cents ? (
                        <div>
                          <h4>{nameOfSalesTaxForCountry(state.country)}</h4>
                          <div>{formatPrice(state.surcharges.result.tax_cents)}</div>
                        </div>
                      ) : null}
                      {state.surcharges.result.shipping_rate_cents ? (
                        <div>
                          <h4>Shipping rate</h4>
                          <div>{formatPrice(state.surcharges.result.shipping_rate_cents)}</div>
                        </div>
                      ) : null}
                    </>
                  ) : null}
                  {visibleDiscounts.length || discount > 0 ? (
                    <div>
                      <h4>
                        Discounts
                        {cart.items.some((item) => !!item.product.ppp_details && item.price !== 0) &&
                        !cart.rejectPppDiscount ? (
                          <WithTooltip
                            tip="This discount is applied based on the cost of living in your country."
                            position="top"
                          >
                            <button
                              className="pill small dismissable"
                              onClick={() => updateCart({ rejectPppDiscount: true })}
                              aria-label="Purchasing power parity discount"
                            >
                              Purchasing power parity discount
                            </button>
                          </WithTooltip>
                        ) : null}
                        {visibleDiscounts.map((code) => (
                          <div
                            className="pill small dismissable"
                            onClick={() =>
                              updateCart({ discountCodes: cart.discountCodes.filter((item) => item !== code) })
                            }
                            key={code.code}
                            aria-label="Discount code"
                          >
                            {code.code}
                          </div>
                        ))}
                      </h4>
                      {discount > 0 ? <div>{formatPrice(-discount)}</div> : null}
                    </div>
                  ) : null}
                  {cart.items.some((item) => item.product.has_offer_codes) ? (
                    <form
                      className="input-with-button"
                      onSubmit={(e) => {
                        e.preventDefault();
                        void applyDiscount(newDiscountCode);
                      }}
                    >
                      <input
                        placeholder="Discount code"
                        value={newDiscountCode}
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
                    <footer>
                      <h4>Total</h4>
                      <div>{formatPrice(total)}</div>
                    </footer>
                    {commissionCompletionTotal > 0 || futureInstallmentsWithoutTipsTotal > 0 ? (
                      <div className="cart-summary">
                        <div>
                          <h4>Payment today</h4>
                          <div>
                            {formatPrice(total - commissionCompletionTotal - futureInstallmentsWithoutTipsTotal)}
                          </div>
                        </div>
                        {commissionCompletionTotal > 0 ? (
                          <div>
                            <h4>Payment after completion</h4>
                            <div>{formatPrice(commissionCompletionTotal)}</div>
                          </div>
                        ) : null}
                        {futureInstallmentsWithoutTipsTotal > 0 ? (
                          <div>
                            <h4>Future installments</h4>
                            <div>{formatPrice(futureInstallmentsWithoutTipsTotal)}</div>
                          </div>
                        ) : null}
                      </div>
                    ) : null}
                  </>
                ) : null}
              </div>
              {recommendedProducts && recommendedProducts.length > 0 ? (
                <section className="paragraphs">
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
            <figure>
              <img src={placeholder} />
            </figure>
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

const CartItemComponent = ({
  item,
  cart,
  updateCart,
  isGift,
}: {
  item: CartItem;
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
    <div role="listitem">
      <section>
        <figure>
          <a href={item.product.url}>
            <Thumbnail url={item.product.thumbnail_url} nativeType={item.product.native_type} />
          </a>
        </figure>
        <section>
          <a href={item.product.url}>
            <h4>{item.product.name}</h4>
          </a>
          <a href={item.product.creator.profile_url}>{item.product.creator.name}</a>
          <footer>
            <ul>
              <li>
                <strong>{item.product.is_multiseat_license ? "Seats:" : "Qty:"}</strong> {item.quantity}
              </li>
              {option?.name ? (
                <li>
                  <strong>{variantLabel(item.product.native_type)}:</strong> {option.name}
                </li>
              ) : null}
              {item.recurrence ? (
                <li>
                  <strong>Membership:</strong> {recurrenceNames[item.recurrence]}
                </li>
              ) : null}
              {item.call_start_time ? (
                <li>
                  <strong>Time:</strong> {formatCallDate(new Date(item.call_start_time), { date: { hideYear: true } })}
                </li>
              ) : null}
            </ul>
          </footer>
        </section>
        <section>
          <span className="current-price" aria-label="Price">
            {formatPrice(convertToUSD(item, price))}
          </span>
          {hasFreeTrial(item, isGift) && item.product.free_trial ? (
            <>
              <span>
                {item.product.free_trial.duration.amount === 1
                  ? `one ${item.product.free_trial.duration.unit}`
                  : `item.product.free_trial.duration.amount ${item.product.free_trial.duration.unit}s`}{" "}
                free
              </span>
              {item.recurrence ? (
                <span>
                  {formatAmountPerRecurrence(item.recurrence, formatPrice(convertToUSD(item, discount.price)))} after
                </span>
              ) : null}
            </>
          ) : item.pay_in_installments && item.product.installment_plan ? (
            <span>in {item.product.installment_plan.number_of_installments} installments</span>
          ) : item.recurrence ? (
            isGift ? (
              recurrenceDurationLabels[item.recurrence]
            ) : (
              recurrenceNames[item.recurrence]
            )
          ) : null}
          <footer>
            <ul>
              {(item.product.rental && !item.product.rental.rent_only) ||
              item.product.is_quantity_enabled ||
              item.product.recurrences ||
              item.product.options.length > 0 ||
              item.product.installment_plan ||
              isPWYW ? (
                <li>
                  <Popover
                    trigger={<span className="link">Configure</span>}
                    open={editPopoverOpen}
                    onToggle={setEditPopoverOpen}
                  >
                    <div className="paragraphs" style={{ width: "24rem" }}>
                      <ConfigurationSelector
                        selection={selection}
                        setSelection={(selection) => {
                          setError(null);
                          setSelection(selection);
                        }}
                        product={item.product}
                        discount={
                          discount.discount && discount.discount.type !== "ppp" ? discount.discount.value : null
                        }
                        showInstallmentPlan
                      />
                      {error ? (
                        <div role="alert" className="danger">
                          {error}
                        </div>
                      ) : null}
                      <Button color="accent" onClick={saveChanges}>
                        Save changes
                      </Button>
                    </div>
                  </Popover>
                </li>
              ) : null}
              <li>
                <button
                  className="link"
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
                </button>
              </li>
            </ul>
          </footer>
        </section>
      </section>
      {item.product.bundle_products.length > 0 ? (
        <section className="footer">
          <h4>This bundle contains...</h4>
          <div role="list" className="cart">
            {item.product.bundle_products.map((bundleProduct) => (
              <div role="listitem" key={bundleProduct.product_id}>
                <section>
                  <figure>
                    <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
                  </figure>
                  <section>
                    <h4>{bundleProduct.name}</h4>
                    <footer>
                      <ul>
                        <li>
                          <strong>Qty:</strong> {bundleProduct.quantity}
                        </li>
                        {bundleProduct.variant ? (
                          <li>
                            <strong>{variantLabel(bundleProduct.native_type)}:</strong> {bundleProduct.variant.name}
                          </li>
                        ) : null}
                      </ul>
                    </footer>
                  </section>
                  <section></section>
                </section>
              </div>
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
};
