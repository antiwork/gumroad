import type { DirectListedLineAllocation, SurchargesResponse } from "$app/data/customer_surcharge";
import {
  CurrencyCode,
  formatMinorUnitPriceWithIntl,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
} from "$app/utils/currency";

import type { CartItem } from "$app/components/Checkout/cartState";
import type { CheckoutPaymentConfig, PaymentMethodType } from "$app/components/Checkout/payment";

type BuyerCurrencyQuote = NonNullable<SurchargesResponse["buyer_currency_quote"]>;
export type BuyerCurrencyLineAllocation = NonNullable<BuyerCurrencyQuote["line_allocations"]>[number];

type CheckoutBuyerCurrencyOptions = {
  cartPermalinks: readonly string[];
  willSaveCard?: boolean;
  paymentMethod?: PaymentMethodType;
};

export type CheckoutBuyerCurrencyDisplay = {
  currencyCode: CurrencyCode;
  rate: number;
  // The backend's authoritative minor-unit scale for the quote currency. Gumroad stores some
  // currencies in non-ISO minor units (e.g. KRW as 1/100 won), so formatting must not rely on
  // the currencies.json single_unit heuristic.
  subunitToUnit: number;
  // The locked buyer-currency total and the server's split of it across the cart lines (in
  // cart order). The checkout table renders these amounts verbatim instead of converting
  // each row itself: independent per-row rounding can visibly disagree with the locked
  // total by a cent, and with the amounts the charge later persists for the receipt.
  presentmentTotalCents: number;
  chargePresentmentTotalCents: number;
  futureInstallmentsPresentmentTotalCents: number | null;
  lineAllocations: BuyerCurrencyLineAllocation[];
};

// Everything the checkout table needs to render a non-USD amount: which currency to label it
// with, how many minor units make one unit of it, and the rate that turns a canonical USD cent
// figure into that currency. Both non-USD checkout lanes produce one of these — the FX-quoted
// buyer-currency lane (rate from the locked quote) and the direct-listed lane
// (rate from the product's stored USD exchange rate) — so every formatting helper below works
// the same way for either, and the rest of the checkout never has to know which lane it is on.
export type CheckoutLocalCurrencyFormat = Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "rate" | "subunitToUnit">;

// The subset of the FX lane's options the listed lane needs: which payment the buyer has selected,
// since only a new card confirmed through the Payment Element charges in the listed currency.
//
// Unlike the FX-quoted lane, `willSaveCard` is deliberately NOT consulted here. On the FX lane,
// saving a card reroutes the charge to the canonical path, so the display must follow. On this
// client-confirm lane the checkbox changes nothing about the charge: the submit branch runs on
// "client-confirm and not a saved card" alone, the ConfirmationToken inherits the element's
// mounted (listed) currency, and the client-confirm payload never carries `save_card`
// (see buildStartCartPurchasePayload in $app/data/purchase.ts). Gating on it would re-show the
// wrong USD summary for every logged-in buyer entering a new card, since the checkbox defaults
// to checked while logged in.
export type CheckoutListedCurrencyOptions = Pick<CheckoutBuyerCurrencyOptions, "paymentMethod"> & {
  usingSavedCard?: boolean;
  hasTip?: boolean;
  hasShipping?: boolean;
};

export const isRecurringUpiPaymentConfig = (checkoutPayment: CheckoutPaymentConfig) => {
  if (checkoutPayment.integration !== "payment_element_client_confirm") return false;

  const options = checkoutPayment.elements_options;
  return (
    checkoutPayment.recurring_upi_registration &&
    checkoutPayment.disable_wallets &&
    !checkoutPayment.payment_element_wallets &&
    options.currency === "inr" &&
    options.presentment_amount_cents !== null &&
    options.presentment_amount_cents > 0 &&
    options.listed_currency_display?.currency === "inr" &&
    options.listed_currency_display.subunit_to_unit === 100 &&
    options.payment_method_types.length === 2 &&
    options.payment_method_types.includes("card") &&
    options.payment_method_types.includes("upi") &&
    !options.stripe_link_enabled &&
    options.stripe_connect_account_id === null
  );
};

export const getCheckoutBuyerCurrencyDisplay = (
  surcharges: SurchargesResponse | null,
  { cartPermalinks, willSaveCard = false, paymentMethod = "card" }: CheckoutBuyerCurrencyOptions,
): CheckoutBuyerCurrencyDisplay | null => {
  const quote = surcharges?.buyer_currency_quote;
  // Saving a card charges through the canonical path (buyer-presentment excludes
  // setup_future_charges in PR 1), and non-card methods (PayPal, the legacy Payment
  // Request Button) quote canonical USD — so both must show the USD totals they charge.
  // Do NOT exclude wallets selected inside the Payment Element (`paymentMethod` stays
  // "card"): their sheet presents this same quote, and the element's mount currency
  // reads this display, so a null here remounts the element in USD and wipes the
  // wallet selection before the sheet can open (gumroad-private#2326).
  if (!quote || willSaveCard || paymentMethod !== "card") return null;

  const lineAllocations = quote.line_allocations;
  if (!Array.isArray(lineAllocations)) return null;
  if (lineAllocations.length !== cartPermalinks.length) return null;
  if (!lineAllocations.every((allocation, index) => allocation.permalink === cartPermalinks[index])) return null;
  if (
    lineAllocations.some(
      (allocation) =>
        allocation.price_cents + allocation.tip_cents + allocation.tax_cents + allocation.shipping_cents !==
        allocation.total_cents,
    )
  )
    return null;
  if (lineAllocations.reduce((sum, allocation) => sum + allocation.total_cents, 0) !== quote.presentment_total_cents)
    return null;

  return {
    currencyCode: quote.currency,
    rate: quote.rate,
    subunitToUnit: quote.subunit_to_unit,
    presentmentTotalCents: quote.presentment_total_cents,
    chargePresentmentTotalCents: quote.charge_presentment_total_cents ?? quote.presentment_total_cents,
    futureInstallmentsPresentmentTotalCents: quote.future_installments_presentment_total_cents ?? null,
    lineAllocations,
  };
};

// The quote token must be sent iff buyer-currency totals were displayed: sending it without the
// display (or vice versa) lets the charged amount diverge from what the buyer confirmed.
export const getCheckoutBuyerCurrencyQuoteToken = (
  surcharges: SurchargesResponse | null,
  options: CheckoutBuyerCurrencyOptions,
): string | null =>
  getCheckoutBuyerCurrencyDisplay(surcharges, options) ? (surcharges?.buyer_currency_quote?.token ?? null) : null;

// Direct-listed presentment, reached through either a method-forced local method or the matching
// buyer-currency card ramp. There is no FX quote, so the cart must be shown in the listed currency.
//
// `rate` is the product's own stored USD exchange rate — the same rate the charge uses to convert
// the USD-side amounts (tax, shipping) back into the listed currency — so the displayed rows and
// the charged amounts agree by construction rather than by coincidence.
//
// Returns null (canonical USD display, today's behavior) unless the server chose this lane AND the
// payment the buyer has actually selected will go through it AND the cart still has the
// uniformly-priced-in-that-currency shape the lane assumes.
//
// The payment-selection gates matter as much as the cart shape, and for the same reason as on the
// FX-quoted lane above: only a new card confirmed through the Payment Element reaches this
// client-confirm presentment path. A saved card (the default whenever the buyer has one on file)
// and PayPal both charge canonical USD through other paths.
export const getCheckoutListedCurrencyDisplay = (
  checkoutPayment: CheckoutPaymentConfig,
  // Only the pricing/plan fields are read, so callers can pass cart items directly and tests
  // don't have to build a whole product. creator stays required, though: made optional, the
  // multi-seller check below would compare undefined to undefined and silently pass.
  cartItems: readonly {
    product: Pick<CartItem["product"], "currency_code" | "exchange_rate"> & {
      creator: Pick<CartItem["product"]["creator"], "id">;
    };
    pay_in_installments?: boolean;
    recurrence?: string | null;
  }[],
  {
    paymentMethod = "card",
    usingSavedCard = false,
    hasTip: _hasTip = false,
    hasShipping = false,
  }: CheckoutListedCurrencyOptions = {},
): CheckoutLocalCurrencyFormat | null => {
  if (checkoutPayment.integration !== "payment_element_client_confirm") return null;
  const listedCurrency = checkoutPayment.elements_options.listed_currency_display;
  if (!listedCurrency) return null;
  // Keep shipping aligned with payment.ts `directListedCardActive`: shipping carts still fall
  // back because the Element amount is not updated from a listed-currency shipping basis.
  if (checkoutPayment.elements_options.direct_listed_card && hasShipping) return null;
  if (usingSavedCard || paymentMethod !== "card") return null;
  if (cartItems.length === 0) return null;

  const firstProduct = cartItems[0]?.product;
  if (!firstProduct) return null;
  for (const item of cartItems) {
    const product = item.product;
    // These fields are editable while the server-owned checkout config remains fixed. Only the
    // narrowly configured recurring UPI lane may keep listed-currency display for a subscription.
    if (item.pay_in_installments) return null;
    if (!!item.recurrence !== isRecurringUpiPaymentConfig(checkoutPayment)) return null;
    if (product.currency_code !== listedCurrency.currency) return null;
    // A zero or missing rate would make every converted row 0; fall back to canonical USD instead.
    if (!(product.exchange_rate > 0)) return null;
    // All items share the currency, so their server-provided rates should be identical; if a
    // reload left them split, converting shared USD rows (tax, shipping) with any one of them
    // could disagree with the charge, so fall back instead of guessing.
    if (product.exchange_rate !== firstProduct.exchange_rate) return null;
    // One ConfirmationToken funds one PaymentIntent, so prepare refuses a multi-seller cart
    // (Checkout::StripePaymentPresenter#direct_listed_card_shape?); don't display a lane it
    // will reject.
    if (product.creator.id !== firstProduct.creator.id) return null;
  }
  if (!(listedCurrency.subunit_to_unit > 0)) return null;

  return {
    currencyCode: firstProduct.currency_code,
    rate: firstProduct.exchange_rate,
    subunitToUnit: listedCurrency.subunit_to_unit,
  };
};

export const toBuyerCurrencyCents = (
  canonicalCents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "rate">,
) => Math.round(canonicalCents * buyerCurrencyDisplay.rate);

export const toCanonicalCents = (
  buyerCurrencyCents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "rate">,
) => Math.round(buyerCurrencyCents / buyerCurrencyDisplay.rate);

// All the buyer-currency amounts the checkout table displays, derived from the server's
// per-line allocation of the locked total so that (line items − discount + tip + tax +
// shipping) sums exactly to the locked total — and each line matches the amount the charge
// later persists for the receipt. Returns null when the allocation doesn't line up with the
// cart lines; the quote usability gate normally catches that first and keeps the checkout in
// canonical currency until a matching response arrives.
export type CheckoutPresentmentAmounts = {
  // Per cart line, in cart order: the allocated (charged) amount plus the line's converted
  // discount, since the table shows pre-discount line prices with the discount itemized in
  // its own row.
  linePriceCents: number[];
  discountCents: number;
  tipCents: number;
  taxCents: number;
  shippingCents: number;
  subtotalCents: number;
  totalCents: number;
};

export const getCheckoutPresentmentAmounts = (
  buyerCurrencyDisplay: CheckoutBuyerCurrencyDisplay | null | undefined,
  cartLines: { permalink: string; discountCents: number }[],
): CheckoutPresentmentAmounts | null => {
  if (!buyerCurrencyDisplay) return null;
  const allocations = buyerCurrencyDisplay.lineAllocations;
  if (allocations.length !== cartLines.length) return null;
  if (!allocations.every((allocation, index) => allocation.permalink === cartLines[index]?.permalink)) return null;

  const lineDiscountCents = cartLines.map((line) =>
    toBuyerCurrencyCents(Math.max(line.discountCents, 0), buyerCurrencyDisplay),
  );
  const linePriceCents = allocations.map(
    (allocation, index) => allocation.price_cents + (lineDiscountCents[index] ?? 0),
  );
  const discountCents = lineDiscountCents.reduce((sum, cents) => sum + cents, 0);
  const tipCents = allocations.reduce((sum, allocation) => sum + allocation.tip_cents, 0);
  const taxCents = allocations.reduce((sum, allocation) => sum + allocation.tax_cents, 0);
  const shippingCents = allocations.reduce((sum, allocation) => sum + allocation.shipping_cents, 0);

  return {
    linePriceCents,
    discountCents,
    tipCents,
    taxCents,
    shippingCents,
    subtotalCents: linePriceCents.reduce((sum, cents) => sum + cents, 0) + tipCents,
    totalCents: buyerCurrencyDisplay.presentmentTotalCents,
  };
};

// The server's listed-currency split of a direct-listed cart, or null when the response predates
// the cart it is being read against. Every consumer must agree on what "matching" means: the
// Element mounts on the sum of these allocations, so a summary that accepted a split the Element
// rejected (or vice versa) would show a total the buyer is not charged.
export const getMatchingDirectListedAllocations = (
  surcharges: Pick<SurchargesResponse, "direct_listed_line_allocations"> | null | undefined,
  cartPermalinks: readonly string[],
): DirectListedLineAllocation[] | null => {
  const allocations = surcharges?.direct_listed_line_allocations;
  if (!allocations || allocations.length !== cartPermalinks.length) return null;
  if (!allocations.every((allocation, index) => allocation.permalink === cartPermalinks[index])) return null;

  return allocations;
};

export const formatPresentmentCents = (
  cents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "subunitToUnit">,
) => formatMinorUnitPriceWithIntl(buyerCurrencyDisplay.currencyCode, cents, buyerCurrencyDisplay.subunitToUnit);

// All the listed-currency amounts the checkout table displays on the direct-listed lane. Two
// different kinds of input meet here, and keeping them straight is the whole point of this
// function:
//
//   * Line prices, discounts and the tip are ALREADY in the listed currency — they come from the
//     cart, which stores the seller's set prices in their own minor units, and the charge bills
//     that listed amount as-is. They must be displayed verbatim: converting them to USD and back
//     would round twice and could disagree with the charge by a cent.
//   * Tax and shipping come back from the surcharge endpoint in USD, so they are converted with
//     the product's stored exchange rate — the same rate
//     Charge::DirectListedPresentment uses on those same two figures,
//     so the totals shown here and the amount charged agree by construction.
//
// Returns null when there is no listed-currency lane, leaving every row in canonical USD.
export type CheckoutListedCurrencyAmounts = {
  // Per cart line, in cart order: the line's undiscounted price, since the table itemizes the
  // discount in its own row.
  linePriceCents: number[];
  discountCents: number;
  tipCents: number;
  taxCents: number;
  taxIncludedCents: number;
  shippingCents: number;
  subtotalCents: number;
  totalCents: number;
};

export const getCheckoutListedCurrencyAmounts = (
  listedCurrency: CheckoutLocalCurrencyFormat | null | undefined,
  {
    lines,
    tipCents,
    usdTaxCents,
    usdTaxIncludedCents,
    usdShippingCents,
    listedTaxCents,
    listedShippingCents,
  }: {
    // The line prices/discounts are already in the listed currency's minor units (that is what the
    // cart holds on this lane); `tipCents` must be converted by the caller, since the tip is
    // canonical USD cents in checkout state.
    lines: { priceCents: number; discountCents: number }[];
    tipCents: number;
    usdTaxCents: number;
    usdTaxIncludedCents: number;
    usdShippingCents: number;
    // The server's per-line tax/shipping sums, when it sent a split matching this cart. Charge
    // time converts each line separately, so its rounded sum can differ by a cent from the one
    // conversion of the aggregate below — prefer the split the charge is actually built from.
    listedTaxCents?: number | null | undefined;
    listedShippingCents?: number | null | undefined;
  },
): CheckoutListedCurrencyAmounts | null => {
  if (!listedCurrency) return null;

  const linePriceCents = lines.map((line) => line.priceCents);
  const discountCents = lines.reduce((sum, line) => sum + Math.max(line.discountCents, 0), 0);
  const taxCents = listedTaxCents ?? toBuyerCurrencyCents(usdTaxCents, listedCurrency);
  const taxIncludedCents = toBuyerCurrencyCents(usdTaxIncludedCents, listedCurrency);
  const shippingCents = listedShippingCents ?? toBuyerCurrencyCents(usdShippingCents, listedCurrency);
  const subtotalCents = linePriceCents.reduce((sum, cents) => sum + cents, 0) + tipCents;

  return {
    linePriceCents,
    discountCents,
    tipCents,
    taxCents,
    taxIncludedCents,
    shippingCents,
    subtotalCents,
    // Tax included in the price is already part of the line prices, so it is only ever displayed,
    // never added — exactly as the canonical USD total treats it.
    totalCents: subtotalCents - discountCents + taxCents + shippingCents,
  };
};

export const formatCheckoutPrice = (
  price: number,
  buyerCurrencyDisplay?: Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "rate" | "subunitToUnit"> | null,
  {
    usdSymbolFormat = "expanded",
    noCentsIfWhole = true,
  }: { usdSymbolFormat?: "expanded" | "short"; noCentsIfWhole?: boolean } = {},
) => {
  const canonicalCents = Math.floor(price);
  if (!buyerCurrencyDisplay) {
    return usdSymbolFormat === "expanded"
      ? formatUSDCentsWithExpandedCurrencySymbol(canonicalCents)
      : formatPriceCentsWithCurrencySymbol("usd", canonicalCents, {
          symbolFormat: "short",
          noCentsIfWhole,
        });
  }

  return formatMinorUnitPriceWithIntl(
    buyerCurrencyDisplay.currencyCode,
    toBuyerCurrencyCents(canonicalCents, buyerCurrencyDisplay),
    buyerCurrencyDisplay.subunitToUnit,
  );
};
