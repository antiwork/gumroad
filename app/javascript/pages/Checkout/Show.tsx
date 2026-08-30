import { Head, router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { flushSync } from "react-dom";
import typia from "typia";

import { type SurchargesResponse } from "$app/data/customer_surcharge";
import { PaymentConfirmedError, startClientConfirmOrderCreation, startOrderCreation } from "$app/data/order";
import { type CartPurchaseResult } from "$app/data/purchase";
import { getPlugins, trackUserActionEvent, trackUserProductAction } from "$app/data/user_action_event";
import { type SavedCreditCard } from "$app/parsers/card";
import { type CardProduct, COMMISSION_DEPOSIT_PROPORTION, type CustomFieldDescriptor } from "$app/parsers/product";
import { isOpenTuple } from "$app/utils/array";
import { assert } from "$app/utils/assert";
import { CurrencyCode, getIsSingleUnitCurrency } from "$app/utils/currency";
import { isValidEmail } from "$app/utils/email";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { assertResponseError } from "$app/utils/request";
import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

import { Button } from "$app/components/Button";
import { Checkout } from "$app/components/Checkout";
import {
  formatCheckoutPrice,
  formatPresentmentCents,
  getCheckoutBuyerCurrencyDisplay,
  getCheckoutListedCurrencyDisplay,
  getCheckoutBuyerCurrencyQuoteToken,
  isRecurringUpiPaymentConfig,
} from "$app/components/Checkout/buyerCurrencyDisplay";
import {
  buildBuyerCurrencyQuoteRecoveryDeps,
  recoverFromInvalidBuyerCurrencyQuote as recoverBuyerCurrencyQuote,
  useLatestCartGetter,
} from "$app/components/Checkout/buyerCurrencyQuoteRecovery";
import {
  type CartItem,
  type CartState,
  convertToUSD,
  CrossSell,
  findCartItem,
  getDiscountedPrice,
  type ProductToAdd,
  type Result,
} from "$app/components/Checkout/cartState";
import {
  buildCartSaveRefreshCallbacks,
  createLaneInvalidationSuppressor,
  type CartSaveCallbacks,
} from "$app/components/Checkout/checkoutPaymentRefresh";
import {
  type CheckoutStyle,
  CheckoutThemeProvider,
  getCheckoutIndicatorCss,
  useCheckoutStyle,
} from "$app/components/Checkout/checkoutTheme";
import { CrossSellModal } from "$app/components/Checkout/CrossSellModal";
import { computeInitialCheckout, type InitialCheckout } from "$app/components/Checkout/initialCheckout";
import {
  canUseStripePaymentElement,
  canUseStripePaymentElementClientConfirm,
  computeTip,
  computeTipForListedLines,
  computeTipsForLines,
  type CheckoutPaymentConfig,
  createReducer,
  getConfiguredDirectListedCurrency,
  getCustomFieldKey,
  getSelectableDirectListedCurrency,
  getTotalPriceFromProducts,
  type Gift,
  isTipSuspiciouslyLarge,
  loadSurcharges,
  type Product,
  requiresReusablePaymentMethod,
  StateContext,
} from "$app/components/Checkout/payment";
import { Receipt } from "$app/components/Checkout/Receipt";
import { TemporaryLibrary } from "$app/components/Checkout/TemporaryLibrary";
import { type OfferedUpsell, UpsellModal } from "$app/components/Checkout/UpsellModal";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { computeOptionPrice } from "$app/components/Product/ConfigurationSelector";
import { showAlert } from "$app/components/server-components/Alert";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOnChange, useOnChangeSync } from "$app/components/useOnChange";
import { useRunOnce } from "$app/components/useRunOnce";

type CheckoutIndexPageProps = {
  cart: CartState | null;
  recommended_products?: CardProduct[]; // InertiaRails.optional prop, loaded after determining screen size
  // Optional because partial reloads can omit a prop that full renders always include.
  checkout_style?: CheckoutStyle | null;
  stripe_fonts_css_source: string;
  checkout: {
    add_products: ProductToAdd[];
    address: { street: string | null; city: string | null; zip: string | null } | null;
    ca_provinces: string[];
    cart_save_debounce_ms: number;
    clear_cart: boolean;
    countries: Record<string, string>;
    country: string | null;
    default_tip_option: number;
    discover_url: string;
    gift: Gift | null;
    max_allowed_cart_products: number;
    paypal_client_id: string;
    recaptcha_key: string | null;
    recaptcha_score_based: boolean;
    recaptcha_challenge_key: string | null;
    saved_credit_card: SavedCreditCard | null;
    state: string | null;
    tip_options: number[];
    us_states: string[];
  };
  // Its own top-level prop rather than a key of `checkout`, because it depends on the cart's
  // contents: the page re-requests it alone after every cart edit so the mounted element always
  // matches the cart on screen. See CheckoutPresenter#checkout_payment_props.
  checkout_payment: CheckoutPaymentConfig;
};

const BUYER_CURRENCY_QUOTE_INVALID_ERROR_CODE = "buyer_currency_quote_invalid";
const BUYER_CURRENCY_QUOTE_INVALID_MESSAGE =
  "The local-currency price changed or expired. Please review the updated total and try again.";
const DUPLICATE_PURCHASE_CONFIRMATION_REQUIRED_ERROR_CODE = "duplicate_purchase_confirmation_required";

function getCartItemUid(item: CartItem) {
  return `${item.product.permalink} ${item.option_id ?? ""}`;
}

const buildCustomFieldValues = (
  fields: CustomFieldDescriptor[],
  values: Record<string, string>,
  product: { permalink: string; bundleProductId?: string | null },
) =>
  fields.map((field) => {
    const key = getCustomFieldKey(field, product);
    return { id: field.id, value: field.type === "text" ? (values[key] ?? "") : values[key] === "true" };
  });

// Identifies the cart for the purpose of choosing a payment lane. Deliberately narrower than the
// cart object, which also carries things the lane does not depend on — the buyer's email is written
// into it on every keystroke, and invalidating the payment configuration on that would disable Pay
// while someone types their address. These are the fields Checkout::StripePaymentPresenter reads to
// choose the lane: which seller each item belongs to, the price, whether it recurs or pays in
// installments, preorder/free-trial status, the native type, and the listed currency.
const paymentLaneCartKeyFor = (cart: CartState) =>
  cart.items
    .map((item) =>
      [
        item.product.creator.id,
        item.product.permalink,
        item.option_id ?? "",
        item.quantity,
        item.price,
        item.recurrence ?? "",
        item.pay_in_installments,
        item.product.is_preorder,
        item.product.free_trial !== null,
        item.product.native_type,
        item.product.currency_code,
      ].join(":"),
    )
    .join("|");

const CheckoutIndexPage = () => {
  const {
    checkout: {
      discover_url,
      countries,
      us_states,
      ca_provinces,
      country,
      state: addressState,
      address,
      clear_cart,
      add_products,
      gift,
      saved_credit_card,
      recaptcha_key,
      recaptcha_score_based,
      recaptcha_challenge_key,
      paypal_client_id,
      max_allowed_cart_products,
      cart_save_debounce_ms,
      tip_options,
      default_tip_option,
    },
    checkout_payment,
    ...props
  } = typia.assert<CheckoutIndexPageProps>(usePage().props);

  const user = useLoggedInUser();
  const email = user?.email ?? props.cart?.email ?? "";
  const fullName = user?.name ?? "";

  // Build the initial cart exactly once.
  //
  // IMPORTANT: this block must stay free of side effects (no analytics calls, no
  // showAlert). Inertia's `useForm` re-invokes a *function* initializer on every
  // render rather than once on mount, so any side effect placed in a function
  // initializer fires on every render. On the checkout-arrival flow (add_products
  // present) that re-fired `begin_checkout`/pixel tracking on each render, which
  // combined with re-render churn to crash mobile Safari ("a problem repeatedly
  // occurred"). See gumroad-private#658. We therefore compute the cart + the
  // one-time tracking intentions in a ref (runs once) and pass a plain value to
  // useForm; the side effects are flushed from a single `useRunOnce` below.
  const initialCheckoutRef = React.useRef<InitialCheckout | null>(null);
  initialCheckoutRef.current ??= computeInitialCheckout({
    cart: props.cart ?? null,
    clearCart: clear_cart,
    addProducts: add_products,
    maxAllowedCartProducts: max_allowed_cart_products,
    url: new URL(window.location.href),
    documentReferrer: document.referrer,
  });
  const initialCheckout = initialCheckoutRef.current;
  const cartForm = useForm<{ cart: CartState }>({ cart: initialCheckout.cart });

  // Flush the initial cart's side effects exactly once, off the render path.
  useRunOnce(() => {
    if (initialCheckout.overLimit) {
      showAlert(`You cannot add more than ${max_allowed_cart_products} products to the cart.`, "error");
      return;
    }
    for (const seller of initialCheckout.sellersToTrack) startTrackingForSeller(seller.id, seller.analytics);
    for (const event of initialCheckout.beginCheckoutEvents) trackProductEvent(event.seller_id, event);
  });
  const reducer = createReducer({
    country,
    email,
    fullName,
    address,
    countries,
    caProvinces: ca_provinces,
    usStates: us_states,
    tipOptions: tip_options,
    defaultTipOption: default_tip_option,
    savedCreditCard: saved_credit_card,
    state: addressState,
    products: getProducts(cartForm.data.cart),
    recaptchaKey: recaptcha_key,
    recaptchaScoreBased: recaptcha_score_based,
    recaptchaChallengeKey: recaptcha_challenge_key,
    paypalClientId: paypal_client_id,
    gift,
    // Always on since the require_email_typo_acknowledgment rollout flag was removed
    // (100% enabled in production since 2025-08; see gumroad-private#1208).
    requireEmailTypoAcknowledgment: true,
    checkoutPayment: checkout_payment,
  });
  const [state, dispatch] = reducer;
  const configuredDirectListedCurrency = getConfiguredDirectListedCurrency(state);
  const selectableDirectListedCurrency = getSelectableDirectListedCurrency(state);
  // Recurring UPI mounts and charges the server-selected INR lane regardless of any quote
  // (clientConfirmBuyerCurrencyPresentmentEnabled excludes it), so the quote must not be
  // displayed — and, below, its token must not be submitted.
  const recurringUpiRegistration = isRecurringUpiPaymentConfig(state.checkoutPayment);
  const buyerCurrencyDisplay =
    configuredDirectListedCurrency || recurringUpiRegistration
      ? null
      : getCheckoutBuyerCurrencyDisplay(state.surcharges.type === "loaded" ? state.surcharges.result : null, {
          cartPermalinks: cartForm.data.cart.items.map((item) => item.product.permalink),
          willSaveCard: state.willSaveCard,
          paymentMethod: state.paymentMethod,
          paymentElementType: state.paymentElementType,
        });
  // The direct-listed currency lane, for the large-tip confirmation below and for the tip
  // basis the order submits. Suppressed whenever the FX-quoted buyer-currency lane is displaying,
  // exactly as the checkout summary's precedence does (`buyerCurrencyDisplay ?? listedCurrency`):
  // the two lanes are near-mutually-exclusive, but a non-USD buyer of a non-USD-priced product can
  // satisfy both, and then it is the quote's allocation that is on screen and locked into the
  // token. Following the same precedence here keeps the modal, the summary and the submitted tip
  // all reading from the one lane that is actually in effect.
  //
  // Also gated on the same dynamic eligibility PaymentForm uses to mount the element (matching
  // the summary in index.tsx): if a discount or surcharge reload drops the loaded canonical total
  // below Stripe's Payment Element minimum, PaymentForm falls back to the CardElement and the
  // charge is canonical USD, so the tip basis and the modal must fall back too.
  const directListedCurrencySelected =
    configuredDirectListedCurrency === null ||
    (selectableDirectListedCurrency !== null && state.buyerCurrency?.toLowerCase() !== "usd");
  const listedCurrency =
    buyerCurrencyDisplay || !canUseStripePaymentElementClientConfirm(state) || !directListedCurrencySelected
      ? null
      : getCheckoutListedCurrencyDisplay(state.checkoutPayment, cartForm.data.cart.items, {
          usingSavedCard: state.usingSavedCard,
          paymentMethod: state.paymentMethod,
          hasTip: computeTip(state) > 0,
          hasShipping: cartForm.data.cart.items.some((item) => item.product.require_shipping),
        });
  // The tip and cart total the confirmation modal quotes, in listed minor units. The tip runs
  // through the submission's own per-line allocation (see computeTipForListedLines) so the modal
  // quotes the figure that will actually be charged, and the cart total is the listed total itself
  // rather than the canonical total converted back — both for the same reason: any separate
  // arithmetic can land a minor unit away from the charge.
  const listedTipLines = cartForm.data.cart.items.map((item) => ({
    price: getDiscountedPrice(cartForm.data.cart, item).price,
    permalink: item.product.permalink,
  }));
  const listedProductTotalCents = listedTipLines.reduce((sum, line) => sum + line.price, 0);
  const listedTipCents = listedCurrency ? computeTipForListedLines(state, listedTipLines) : 0;
  const [results, setResults] = React.useState<Result[] | null>(null);
  const [checkoutStyle, capturePurchasedCheckoutStyle] = useCheckoutStyle(
    props.checkout_style,
    cartForm.data.cart.items.map(({ product }) => product.creator.id),
  );
  const [canBuyerSignUp, setCanBuyerSignUp] = React.useState(false);
  const [redirecting, setRedirecting] = React.useState(false);
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();
  const isMobile = !useIsAboveBreakpoint("sm");
  const cartProductIdsKey = cartForm.data.cart.items.map(({ product }) => product.id).join(",");
  React.useEffect(() => {
    if (state.status.type !== "input" || cartProductIdsKey === "") return;
    router.reload({
      data: {
        cart_product_ids: cartProductIdsKey.split(","),
        limit: isMobile ? 2 : 6,
      },
      preserveUrl: true,
      only: ["recommended_products"],
    });
  }, [state.status.type, isMobile, cartProductIdsKey]);

  const completedOfferIds = React.useRef(new Set()).current;
  const [offers, setOffers] = React.useState<
    null | ((CrossSell & { type: "cross-sell" }) | (OfferedUpsell & { type: "upsell" }))[]
  >(null);
  const currentOffer = offers?.[0];

  // Because the Apple Pay dialog has to be opened synchronously, we need
  // to precompute what the surcharges would be if the offer were accepted.
  // Without this, the price displayed on the Apple Pay payment sheet
  // won't reflect the accepted offer.
  const [surchargesIfAccepted, setSurchargesIfAccepted] = React.useState<SurchargesResponse | null>(null);
  useOnChange(
    () =>
      void loadSurcharges({ ...state, products: getProducts(getCartIfAccepted()) })
        .then(setSurchargesIfAccepted)
        .catch((e: unknown) => {
          assertResponseError(e);
          showAlert("Sorry, something went wrong. Please try again.", "error");
          dispatch({ type: "cancel" });
        }),
    [currentOffer],
  );

  // Lets acceptOffer tell the passive lane-key effect "I already invalidated for this exact cart",
  // for that one echo only. See createLaneInvalidationSuppressor for why the claim is consumed
  // rather than kept.
  const laneInvalidation = React.useRef(createLaneInvalidationSuppressor()).current;
  const completeOffer = () => {
    if (!currentOffer) return;
    completedOfferIds.add(currentOffer.id);
    if (offers.length === 1) dispatch({ type: "validate" });
    setSurchargesIfAccepted(null);
    setOffers((prevOffers) => prevOffers?.slice(1) ?? prevOffers);
  };
  const acceptOffer = () => {
    const newCart = getCartIfAccepted();
    flushSync(() => cartForm.setData({ cart: newCart }));
    // Synchronously, not via the passive effect below: completeOffer can dispatch "validate" in
    // the same tick, and a passive invalidation would run after it — submitting through a payment
    // configuration computed for the pre-offer cart. An accepted offer changes the cart's items,
    // so it can change the lane (a bundle's listed currency, a recurring tier) exactly like any
    // other edit.
    //
    // Record which cart this invalidation covers so the passive effect, which fires for this same
    // cart change, does not repeat it. A repeat would look like a fresh buyer edit and cancel the
    // resume that the "validate" below arms.
    laneInvalidation.claim(paymentLaneCartKeyFor(newCart));
    dispatch({ type: "invalidate-checkout-payment" });
    // Unconditionally, including when the accepted cart's quote has not arrived yet. The products
    // have to be in state before completeOffer's "validate" runs, because that "validate" is the
    // dispatch responsible for pointing out required fields belonging to the product the buyer just
    // added — and it can only see fields for products it has. Making this conditional on the quote
    // meant that whether the cross-sold product's required fields were flagged depended on whether
    // a background surcharge request happened to have landed, which is a race the buyer can lose:
    // upsell_spec.rb:489 loses it, and the fields sit un-flagged with no explanation.
    //
    // Passing no surcharges leaves the quote pending, which cancels the pipeline back to "input".
    // That is the same thing the passive [cartForm.data.cart] effect does one tick later, so this is
    // the existing behaviour brought forward rather than a new one, and it is the fail-closed
    // direction: the totals really are not yet ones a charge would honour.
    dispatch({
      type: "update-products",
      products: getProducts(newCart),
      ...(surchargesIfAccepted ? { surcharges: surchargesIfAccepted } : {}),
    });
    completeOffer();
  };

  // show (the Stripe Payment Request method that triggers the Apple Pay
  // modal) can't be called in asynchronous code, so we have to use a
  // synchronous layout effect.
  useOnChangeSync(() => {
    if (state.status.type !== "offering") return;
    const seenCrossSellIds = new Set();
    const newOffers = [
      ...cartForm.data.cart.items
        .flatMap(({ product }) => product.cross_sells)
        .filter((crossSell) => {
          const seen = seenCrossSellIds.has(crossSell.id);
          seenCrossSellIds.add(crossSell.id);
          return (
            !completedOfferIds.has(crossSell.id) &&
            !seen &&
            !findCartItem(
              cartForm.data.cart,
              crossSell.offered_product.product.permalink,
              crossSell.offered_product.option_id,
            )
          );
        })
        .map((crossSell) => ({ type: "cross-sell", ...crossSell }) as const),
      ...cartForm.data.cart.items.flatMap((item) => {
        const currentOption = item.product.options.find(({ id }) => id === item.option_id);
        const offeredOption = item.product.options.find(({ id }) => id === currentOption?.upsell_offered_variant_id);
        return item.product.upsell &&
          !completedOfferIds.has(item.product.upsell.id) &&
          offeredOption &&
          !findCartItem(cartForm.data.cart, item.product.permalink, offeredOption.id)
          ? ({ type: "upsell", ...item.product.upsell, item, offeredOption } as const)
          : [];
      }),
    ];
    if (newOffers.length === 0) dispatch({ type: "validate" });
    setOffers(newOffers);
  }, [state.status.type]);

  function getProducts(state: CartState): Product[] {
    return state.items.map((item) => {
      const { price, discount } = getDiscountedPrice(state, item);
      // What one renewal will charge, for describing the recurring agreement on the Apple Pay
      // sheet. A discount limited to the first billing cycle doesn't apply to renewals, so
      // renewals bill the undiscounted price; any other discount carries over.
      const discountLimitedToFirstCycle =
        (discount?.type === "code" || discount?.type === "cross-sell") &&
        discount.value.duration_in_billing_cycles === 1;
      const renewalPrice = discountLimitedToFirstCycle ? item.price * item.quantity : price;
      return {
        permalink: item.product.permalink,
        uid: getCartItemUid(item),
        name: item.product.name,
        creator: item.product.creator,
        requireShipping: item.product.require_shipping,
        supportsPaypal: item.product.supports_paypal,
        customFields: item.product.custom_fields,
        bundleProductCustomFields: item.product.bundle_products.map(({ product_id, name, custom_fields }) => ({
          product: { id: product_id, name },
          customFields: custom_fields,
        })),
        testPurchase: user ? item.product.creator.id === user.id : false,
        requirePayment: !!item.product.free_trial && price > 0,
        quantity: item.quantity,
        hasFreeTrial: !!item.product.free_trial,
        hasTippingEnabled: item.product.has_tipping_enabled,
        isPreorder: item.product.is_preorder,
        price: convertToUSD(item, price),
        // The server renders the recurring UPI Element from the selected listed amount before
        // discounts. Keep that basis stable when a limited discount changes only today's charge.
        listedPriceCents: item.price * item.quantity,
        listedChargePriceCents: price,
        listedCurrencyExchangeRate: item.product.exchange_rate,
        renewalPriceCents: item.recurrence ? Math.round(convertToUSD(item, renewalPrice)) : null,
        payInInstallments: item.pay_in_installments,
        installmentPlan: item.product.installment_plan
          ? { numberOfInstallments: item.product.installment_plan.number_of_installments }
          : null,
        durationInMonths: item.product.duration_in_months,
        recurrence: item.recurrence,
        forceNewSubscription: item.force_new_subscription,
        recommended_by: item.recommended_by,
        shippableCountryCodes: item.product.shippable_country_codes,
        nativeType: item.product.native_type,
        canGift: item.product.can_gift,
      };
    });
  }

  const [showLargeTipConfirmation, setShowLargeTipConfirmation] = React.useState(false);
  const largeTipConfirmedRef = React.useRef(false);

  // Line-item uids the buyer has explicitly confirmed they want to buy again after
  // not_double_charged flagged an existing successful purchase of the same product.
  const confirmedDuplicatePurchaseUidsRef = React.useRef(new Set<string>());
  const [duplicatePurchaseConfirmation, setDuplicatePurchaseConfirmation] = React.useState<{
    uids: string[];
    productNames: string[];
  } | null>(null);

  // The cart stays editable while the charge request is in flight — the Edit and Remove
  // controls in the cart rows are not disabled during processing — so the buyer can change a
  // quantity, an option, or a pay-what-you-want price, or drop an item entirely, between
  // pressing Pay and the server answering. This getter always reads the cart from the latest
  // committed render, so the recovery writes back whatever the buyer is holding at that
  // moment rather than the snapshot from the render that started the charge, which would
  // resurrect selections they had already changed and then quote them.
  const getLatestCart = useLatestCartGetter(cartForm.data.cart);

  // Recovers a checkout whose local-currency quote the server refused at charge time. The
  // reasoning lives with the helper in buyerCurrencyQuoteRecovery.ts.
  function recoverFromInvalidBuyerCurrencyQuote(lineItems: CartPurchaseResult["lineItems"]) {
    recoverBuyerCurrencyQuote({
      lineItems,
      ...buildBuyerCurrencyQuoteRecoveryDeps({
        getLatestCart,
        setCart: (cart) => cartForm.setData({ cart }),
        getProducts,
        dispatchUpdateProducts: (products) => dispatch({ type: "update-products", products }),
      }),
    });
  }

  async function pay() {
    if (state.status.type !== "finished") return;
    if (isTipSuspiciouslyLarge(state) && !largeTipConfirmedRef.current) {
      setShowLargeTipConfirmation(true);
      return;
    }
    try {
      await trackUserActionEvent("process_payment");
      if (user) {
        await Promise.all(
          cartForm.data.cart.items.map((item) =>
            trackUserProductAction({
              name: "process_payment",
              permalink: item.product.permalink,
              fromOverlay: false,
              wasRecommended: !!item.recommended_by,
            }),
          ),
        );
      }
      const requestData = {
        email: state.email,
        fullName: state.fullName,
        zipCode: state.zipCode,
        state: state.state,
        paymentMethod: state.status.paymentMethod,
        usedStripePaymentElement: canUseStripePaymentElement(state),
        shippingInfo: cartForm.data.cart.items.some((item) => item.product.require_shipping)
          ? {
              save: state.saveAddress,
              country: state.country,
              state: state.state,
              city: state.city,
              zipCode: state.zipCode,
              fullName: state.fullName,
              streetAddress: state.address,
            }
          : null,
        taxCountryElection: state.country,
        vatId: state.vatId,
        giftInfo: state.gift
          ? state.gift.type === "anonymous"
            ? { giftNote: state.gift.note, gifteeId: state.gift.id }
            : { giftNote: state.gift.note, gifteeEmail: state.gift.email }
          : null,
        eventAttributes: {
          plugins: getPlugins(),
          friend: document.querySelector<HTMLInputElement>(".friend")?.value ?? null,
          url_parameters: window.location.search,
          locale: navigator.language,
        },
        recaptchaResponse: state.status.recaptchaResponse ?? null,
        recaptchaChallengeFallback: state.status.challengeFallback ?? false,
        buyerCurrencyQuote:
          configuredDirectListedCurrency || recurringUpiRegistration
            ? null
            : getCheckoutBuyerCurrencyQuoteToken(state.surcharges.type === "loaded" ? state.surcharges.result : null, {
                cartPermalinks: cartForm.data.cart.items.map((item) => item.product.permalink),
                willSaveCard: state.willSaveCard,
                paymentMethod: state.paymentMethod,
                paymentElementType: state.paymentElementType,
              }),
        lineItems: (() => {
          // Precompute each line's discounted price bases once so the tip can be allocated
          // across the whole cart in a single pass. The per-line tips must sum exactly to
          // the tip the buyer selected AND match what loadSurcharges sent for the quote —
          // the buyer-currency quote token is verified at charge time against the
          // purchases' line totals, so a different rounding here would fail every
          // affected charge (see computeTipsForLines).
          const linePricing = cartForm.data.cart.items.map((item) => {
            const discounted = getDiscountedPrice(cartForm.data.cart, item);

            const discountedPriceTotal = discounted.price;
            let discountedPriceToChargeNow = discounted.price;
            if (item.product.native_type === "commission") {
              discountedPriceToChargeNow *= COMMISSION_DEPOSIT_PROPORTION;
            } else if (item.pay_in_installments && item.product.installment_plan) {
              discountedPriceToChargeNow = calculateFirstInstallmentPaymentPriceCents(
                discountedPriceTotal,
                item.product.installment_plan.number_of_installments,
              );
            }
            return { item, discounted, discountedPriceTotal, discountedPriceToChargeNow };
          });
          const lineTips = computeTipsForLines(
            state,
            linePricing.map(({ item, discountedPriceTotal, discountedPriceToChargeNow }) => ({
              // Installment plans charge the full tip upfront with the first payment, so
              // their tip share is based on the line's full price rather than today's charge.
              price:
                item.pay_in_installments && item.product.installment_plan
                  ? discountedPriceTotal
                  : discountedPriceToChargeNow,
              permalink: item.product.permalink,
            })),
            // These bases are the products' own minor units. On the method-forced lane that is a
            // non-USD currency the charge bills directly, so a fixed tip is allocated from the
            // amount the buyer typed in that currency — typing R$10.00 bills R$10.00 rather than
            // the R$9.96 that round-tripping it through canonical USD cents produces.
            { basis: listedCurrency ? "listed" : "canonical" },
          );

          return linePricing.map(({ item, discounted, discountedPriceToChargeNow }, index) => {
            const tipCents = lineTips[index] ?? null;
            return {
              permalink: item.product.permalink,
              uid: getCartItemUid(item),
              isMultiBuy: requiresReusablePaymentMethod(state),
              isPreorder: item.product.is_preorder,
              isRental: item.rent,
              perceivedPriceCents: discountedPriceToChargeNow + (tipCents ?? 0),
              priceCents: item.price * item.quantity + (tipCents ?? 0),
              tipCents,
              quantity: item.quantity,
              priceRangeUnit: null,
              priceId:
                item.product.recurrences?.enabled.find(({ recurrence }) => item.recurrence === recurrence)?.id ?? null,
              perceivedFreeTrialDuration: item.product.free_trial?.duration ?? null,
              variants: item.option_id ? [item.option_id] : [],
              callStartTime: item.call_start_time,
              payInInstallments: item.pay_in_installments,
              discountCode: discounted.discount?.type === "code" ? discounted.discount.code : null,
              isPppDiscounted:
                !!item.product.ppp_details &&
                !cartForm.data.cart.rejectPppDiscount &&
                discounted.discount?.type === "ppp" &&
                item.price !== 0,
              acceptsPppDiscount: !!item.product.ppp_details && !cartForm.data.cart.rejectPppDiscount,
              forceNewSubscription: item.force_new_subscription,
              confirmedDuplicatePurchase: confirmedDuplicatePurchaseUidsRef.current.has(getCartItemUid(item)),
              acceptedOffer: item.accepted_offer ?? null,
              bundleProducts: item.product.bundle_products.map((bundleProduct) => ({
                productId: bundleProduct.product_id,
                quantity: bundleProduct.quantity,
                variantId: bundleProduct.variant?.id ?? null,
                customFields: buildCustomFieldValues(bundleProduct.custom_fields, state.customFieldValues, {
                  permalink: item.product.permalink,
                  bundleProductId: bundleProduct.product_id,
                }),
              })),
              recommendedBy: item.recommended_by,
              recommenderModelName: item.recommender_model_name,
              affiliateId: item.affiliate_id,
              customFields: buildCustomFieldValues(item.product.custom_fields, state.customFieldValues, item.product),
              // TODO: Pass item.url_parameters (Record<string, string>) here after new checkout experience is rolled out
              urlParameters: JSON.stringify(item.url_parameters),
              referrer: item.referrer,
            };
          });
        })(),
      };
      const result =
        requestData.paymentMethod.type === "payment-element-client-confirm"
          ? await startClientConfirmOrderCreation(
              requestData,
              requestData.paymentMethod.confirmationTokenId,
              requestData.paymentMethod.selectedMethodType,
              cartForm.data.cart.discountCodes,
            )
          : await startOrderCreation(requestData, cartForm.data.cart.discountCodes);

      // The CAPTCHA check refused the order on risk score alone, which is not something the buyer
      // can act on — so run the challenge key instead and resubmit with its token
      // (gumroad-private#1590). No alert: the challenge is the next step, and the offer is
      // single-use server-side, so it cannot loop.
      if (result.recaptchaChallengeAvailable) {
        dispatch({ type: "retry-recaptcha-challenge" });
        return;
      }

      const results = Object.entries(result.lineItems).flatMap(([key, result]) => {
        const [permalink, optionId] = key.split(" ");
        const item = cartForm.data.cart.items.find(
          (item) => item.product.permalink === permalink && item.option_id === (optionId || null),
        );
        return item ? { item, result } : [];
      });
      assert(isOpenTuple(results, 1), "startCartPayment returned empty results");

      if (
        results.some(
          ({ result }) =>
            !result.success && "error_code" in result && result.error_code === BUYER_CURRENCY_QUOTE_INVALID_ERROR_CODE,
        )
      ) {
        showAlert(BUYER_CURRENCY_QUOTE_INVALID_MESSAGE, "warning");
        dispatch({ type: "cancel" });
        recoverFromInvalidBuyerCurrencyQuote(result.lineItems);
        return;
      }

      // Server refused a same-product repeat charge (Purchase#not_double_charged) rather than
      // silently double-charging on a resubmit. Offer an explicit confirmation and retry once
      // confirmed — mirrors the large-tip confirmation: state stays "finished" so the retry
      // effect below can resubmit without the buyer pressing Pay. Only offered when EVERY
      // failure is a confirmable duplicate: "Buy again" resubmits the whole remaining cart, so
      // a line that failed for any other reason must go back through the normal failure path
      // for the buyer to re-review before it can be charged.
      const failedResults = results.filter(({ result }) => !result.success);
      const duplicatePurchaseResults = failedResults.filter(
        ({ result }) =>
          "error_code" in result && result.error_code === DUPLICATE_PURCHASE_CONFIRMATION_REQUIRED_ERROR_CODE,
      );
      if (duplicatePurchaseResults.length > 0 && duplicatePurchaseResults.length === failedResults.length) {
        // Drop the successful lines from the cart now — same as the failedItems filter below —
        // so "Buy again" only resubmits the lines awaiting confirmation.
        const remainingItems = cartForm.data.cart.items.flatMap((item) => {
          const lineItem = result.lineItems[getCartItemUid(item)];
          return lineItem && !lineItem.success
            ? {
                ...item,
                ...lineItem.updated_product,
                quantity: lineItem.updated_product?.quantity || item.quantity,
                accepted_offer: null,
              }
            : [];
        });
        debouncedSaveCartState.cancel();
        cartForm.setData((prev) => ({ cart: { ...prev.cart, items: remainingItems } }));
        setDuplicatePurchaseConfirmation({
          uids: duplicatePurchaseResults.map(({ item }) => getCartItemUid(item)),
          productNames: duplicatePurchaseResults.map(({ item }) => item.product.name),
        });
        return;
      }

      const failedItems = cartForm.data.cart.items.flatMap((item) => {
        const lineItem = result.lineItems[getCartItemUid(item)];
        return lineItem && !lineItem.success
          ? {
              ...item,
              ...lineItem.updated_product,
              quantity: lineItem.updated_product?.quantity || item.quantity,
              accepted_offer: null,
            }
          : [];
      });

      let redirectTo: null | "content-page" | "library-page" = null;
      const firstResult = results[0].result;
      if (failedItems.length === 0) {
        if (
          results.length === 1 &&
          firstResult.success &&
          firstResult.content_url != null &&
          (!firstResult.bundle_products?.length || (user && !firstResult.test_purchase_notice))
        )
          redirectTo = "content-page";
        else if (
          !!user &&
          user.confirmed &&
          results.every(({ result }) => result.success && result.content_url != null && !result.test_purchase_notice)
        )
          redirectTo = "library-page";
      }

      for (const { result, item } of results) {
        if (!result.success) continue;
        if (!redirectTo) {
          trackProductEvent(item.product.creator.id, {
            action: "purchased",
            seller_id: result.seller_id,
            permalink: result.permalink,
            purchase_external_id: result.id,
            currency: result.currency_type.toUpperCase(),
            product_name: result.name,
            value: result.non_formatted_price,
            valueIsSingleUnit: getIsSingleUnitCurrency(typia.assert<CurrencyCode>(result.currency_type)),
            quantity: result.quantity,
            tax: result.non_formatted_seller_tax_amount,
            ...(item.product.buyer_currency_display
              ? { buyer_currency_display: item.product.buyer_currency_display }
              : {}),
            ...(result.buyer_presentment_currency
              ? {
                  buyer_presentment_currency: result.buyer_presentment_currency,
                  buyer_presentment_value: result.buyer_presentment_value,
                }
              : {}),
          });
        }
        if (result.has_third_party_analytics && !redirectTo)
          addThirdPartyAnalytics({ permalink: result.permalink, location: "receipt", purchaseId: result.id });
      }

      setRedirecting(!!redirectTo);

      // A save scheduled before Pay can still be pending here — an email keystroke's debounce, or
      // a timer a backgrounded tab (wallet/Link popup flows) held until focus returned. It carries
      // the pre-purchase cart, so letting it fire now re-persists the items that were just bought;
      // the buyer sees their cart come back and pays again (gumroad-private#1793).
      debouncedSaveCartState.cancel();

      cartForm.setData((prev) => ({
        cart: {
          ...prev.cart,
          items: failedItems,
          discountCodes: result.offerCodes.map((discountCode) => ({
            ...discountCode,
            fromUrl: prev.cart.discountCodes.find(({ code }) => code === discountCode.code)?.fromUrl ?? false,
          })),
          rejectPppDiscount: false,
        },
      }));

      if (redirectTo === "content-page" && firstResult.success && firstResult.content_url) {
        const contentUrl = new URL(firstResult.content_url);
        if (firstResult.native_type === "coffee") contentUrl.searchParams.set("purchase_email", state.email);
        else contentUrl.searchParams.set("receipt", "true");
        window.location.href = contentUrl.toString();
      } else if (redirectTo === "library-page") {
        const purchases = results.flatMap(({ result }) => (result.success ? result.id : []));
        const libraryUrl = new URL(Routes.library_url());
        for (const purchase of purchases) libraryUrl.searchParams.append("purchase_id[]", purchase);
        window.location.href = libraryUrl.toString();
      }

      capturePurchasedCheckoutStyle(results.map(({ item }) => item.product.creator.id));
      setResults(results);
      setCanBuyerSignUp(result.canBuyerSignUp);
    } catch (e) {
      // The card was captured, so never drop the buyer back into a resubmittable cart. The return
      // page resolves the payment to its durable outcome (receipt, pending, or retry with the cart
      // restored) — a transient toast over an emptied cart reads like the purchase vanished.
      if (e instanceof PaymentConfirmedError) {
        if (e.returnUrl) {
          setRedirecting(true);
          window.location.href = e.returnUrl;
          return;
        }
        showAlert(
          "Your payment is being processed — check your email for your receipt. Please do not pay again.",
          "warning",
        );
        // Same stale-save hazard as the success path above: a pre-purchase save still pending
        // would re-fill the cart this line just emptied.
        debouncedSaveCartState.cancel();
        cartForm.setData((prev) => ({ cart: { ...prev.cart, items: [] } }));
        dispatch({ type: "cancel" });
        return;
      }
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
      dispatch({ type: "cancel" });
    }
  }
  React.useEffect(() => void pay(), [state.status]);
  React.useEffect(() => {
    if (largeTipConfirmedRef.current && state.status.type === "finished") void pay();
  }, [showLargeTipConfirmation]);
  React.useEffect(() => {
    largeTipConfirmedRef.current = false;
  }, [state.tip]);
  React.useEffect(() => {
    if (
      duplicatePurchaseConfirmation === null &&
      confirmedDuplicatePurchaseUidsRef.current.size > 0 &&
      state.status.type === "finished"
    ) {
      // One retry attempt is all the confirmation buys — a later repeat of the same product
      // gets asked again. Cleared once pay() settles rather than immediately: pay()'s first
      // await runs before it builds the line items that read this ref.
      void pay().finally(() => {
        confirmedDuplicatePurchaseUidsRef.current = new Set();
      });
    }
  }, [duplicatePurchaseConfirmation]);

  // A save can finish without delivering a recomputed configuration (dropped connection, timeout,
  // 500). The hold on Pay is NOT released in that case — see checkoutPaymentRefresh for why a lost
  // response cannot be read as "the edit didn't persist" — instead the save is re-issued, and if
  // that one comes back empty-handed too the buyer is asked to reload.
  //
  // The recovery has to be a save rather than a bare re-request of the configuration: a save sends
  // the cart the client currently holds, so its answer is the configuration for that same cart.
  // Saves also supersede one another, so a recovery cannot race the buyer's next edit.
  //
  // Once payment starts, the cart the buyer edited is no longer the cart that matters, and a save
  // still carrying it must not be allowed to answer: its response re-renders `cart` from the
  // pre-payment state, putting the purchased items and the checkout form back over the receipt
  // (gumroad-private#1793). What cannot be blocked is the save *after* checkout, which persists the
  // failed items into a fresh cart — so this is a staleness test, not a pause. Saves issued before
  // payment started are dropped; saves issued from the trimmed post-checkout cart are the current
  // generation and go through.
  const cartSaveGenerationRef = React.useRef(0);
  const paymentStarted = state.status.type !== "input" && state.status.type !== "offering";
  React.useEffect(() => {
    if (!paymentStarted) return;
    // Anything already queued was built from the pre-payment cart; a queued save has not been
    // issued yet, so cancelling is strictly better than letting it start and be discarded.
    debouncedSaveCartStateRef.current.cancel();
    // `onBefore` only gates a save before it is sent. A save that had already been dispatched
    // (and so already passed that gate) when payment started is still in flight here, and its
    // response would otherwise repaint the receipt with the pre-payment cart. Cancelling the
    // Inertia visit itself marks it `cancelled`, which the recovery callbacks in
    // checkoutPaymentRefresh already treat as a no-op — see the `visit?.cancelled` guard in
    // `onFinish` — so this cannot race a later, legitimate save.
    cartForm.cancel();
    cartSaveGenerationRef.current += 1;
  }, [paymentStarted]);

  const saveCart = (callbacks: CartSaveCallbacks) => {
    const generation = cartSaveGenerationRef.current;

    cartForm.patch(Routes.checkout_path(), {
      // checkout_payment comes back with the save because it is derived from the cart: which
      // element this checkout mounts, and in which currency, can change when the cart changes.
      // Asking for it in the same request means there is no window where the persisted cart and
      // the payment configuration on screen describe different carts. checkout_style rides along
      // for the same reason: branding cannot outlive a one-to-mixed-seller transition.
      only: ["cart", "flash", "checkout_payment", "checkout_style"],
      preserveUrl: true,
      preserveScroll: true,
      // The generation is captured when the save is issued, so this refuses exactly the saves that
      // were built from a cart payment has since moved past — and lets a post-checkout save through.
      onBefore: () => generation === cartSaveGenerationRef.current,
      ...callbacks,
    });
  };
  // Held in a ref so a recovery started by an earlier save calls the current render's save rather
  // than one closed over stale cart data.
  const saveCartRef = React.useRef(saveCart);
  saveCartRef.current = saveCart;
  // The lane key of the cart as it stands right now, for saves to compare their answer against.
  // A ref for the same reason as the save above: a debounce or a recovery reads it outside the
  // render that scheduled it.
  const currentPaymentLaneCartKeyRef = React.useRef("");

  const debouncedSaveCartState = useDebouncedCallback(() => {
    saveCartRef.current(
      buildCartSaveRefreshCallbacks({
        save: (callbacks) => saveCartRef.current(callbacks),
        currentCartKey: () => currentPaymentLaneCartKeyRef.current,
        // The one path that lifts the hold on Pay. The save that asked is the only place that knows
        // the configuration describes the cart the buyer is looking at — see checkoutPaymentRefresh.
        // Re-validated here because it is read straight off the response rather than out of the
        // props typia has already checked.
        onDelivered: (checkoutPayment) =>
          dispatch({
            type: "update-checkout-payment",
            checkoutPayment: typia.assert<CheckoutPaymentConfig>(checkoutPayment),
          }),
        onUnrecoverable: (message) => showAlert(message, "error"),
      }),
    );
  }, cart_save_debounce_ms);
  // The pre-payment cancel above runs in an effect declared before this callback exists, so it
  // reaches it through a ref rather than by ordering the declarations around each other.
  const debouncedSaveCartStateRef = React.useRef(debouncedSaveCartState);
  debouncedSaveCartStateRef.current = debouncedSaveCartState;

  // Clean URL params after initial render to avoid stale URL references during Inertia updates
  useRunOnce(() => {
    const url = new URL(window.location.href);
    const searchParams = new URLSearchParams([...url.searchParams].filter(([key]) => key === "_gl"));
    url.search = searchParams.toString();
    router.replace({ url: url.toString(), preserveState: true, preserveScroll: true });
  });
  React.useEffect(() => {
    debouncedSaveCartState();
    if (state.status.type === "input") {
      dispatch({ type: "update-products", products: getProducts(cartForm.data.cart) });
    }
  }, [cartForm.data.cart]);
  // The cart changed in a way that can move it to a different payment lane, so the configuration
  // on screen was computed for the previous cart. Mark it stale (Pay stays disabled) until the
  // save above returns the recomputed one.
  //
  // Keyed on the items' lane-relevant fields rather than the cart object, because the cart object
  // also carries things the payment lane does not depend on — the buyer's email is written into it
  // on every keystroke (see the effect below), and invalidating on that would disable Pay while
  // someone types their address. These are the fields Checkout::StripePaymentPresenter reads to
  // choose the lane: which seller each item belongs to, the price, whether it recurs or pays in
  // installments, preorder/free-trial status, the native type, and the listed currency.
  const paymentLaneCartKey = paymentLaneCartKeyFor(cartForm.data.cart);
  currentPaymentLaneCartKeyRef.current = paymentLaneCartKey;
  useOnChange(() => {
    // Skip the invalidation when acceptOffer already made it for this exact cart. Accepting an
    // offer changes the cart, so this passive effect fires for that change too — but acceptOffer
    // has already dispatched the invalidation synchronously (it has to, so the "validate" it
    // dispatches in the same tick sees the stale flag) and that "validate" has already been refused
    // and armed for resume. A second invalidation here would read as "the buyer edited the cart
    // again" and drop the resume, stranding the checkout with no purchase and no feedback — the
    // deadlock this echo caused before.
    //
    // The claim covers only that one echo: it is consumed here, so a later edit that returns the
    // cart to the accepted key is invalidated normally. See createLaneInvalidationSuppressor.
    if (laneInvalidation.shouldSuppressLaneInvalidation(paymentLaneCartKey)) return;
    dispatch({ type: "invalidate-checkout-payment" });
  }, [paymentLaneCartKey]);
  // Deliberately NOT a watcher on the checkout_payment prop. A configuration arriving in the props
  // is not evidence that it describes the cart on screen — a rejected edit and a save the buyer's
  // next edit overtook both deliver a well-formed configuration for a cart the buyer no longer has,
  // and a prop watcher adopts all three cases identically. Adoption is dispatched by the save that
  // asked instead, via onDelivered above; the cart PATCH is the only request that asks for this
  // prop, so nothing else can supply one.
  useOnChange(() => {
    if (state.email.trim() === "" || isValidEmail(state.email.trim())) {
      // @ts-expect-error FormDataKeys recurses into Product.cross_sells; CartState is still correct at runtime
      cartForm.setData("cart.email", state.email.trim());
    }
  }, [state.email]);

  const getCartIfAccepted = () => {
    if (currentOffer?.type === "cross-sell") {
      const originalCartItems = cartForm.data.cart.items.filter(({ product }) =>
        product.cross_sells.some(({ id }) => id === currentOffer.id),
      );
      const originalCartItem = originalCartItems[0];
      if (originalCartItem) {
        // When a replace-type cross-sell offers a bundle, also drop any cart items for products
        // that are already inside that bundle (e.g. products added by earlier accepted add-on
        // cross-sells). Those items aren't tagged with this offer's id (their cross_sells were
        // stripped when they were injected mid-checkout), so the originalCartItems filter alone
        // would leave the buyer purchasing the bundle plus its own contents.
        const offeredBundleProductIds = new Set(
          currentOffer.offered_product.product.bundle_products.map(({ product_id }) => product_id),
        );
        const replacedItems = (item: CartItem) =>
          originalCartItems.includes(item) || offeredBundleProductIds.has(item.product.id);
        return {
          ...cartForm.data.cart,
          items: [
            ...(currentOffer.replace_selected_products
              ? cartForm.data.cart.items.filter((item) => !replacedItems(item))
              : cartForm.data.cart.items),
            {
              ...currentOffer.offered_product,
              product: { ...currentOffer.offered_product.product, cross_sells: [] },
              quantity: 1,
              url_parameters: originalCartItem.url_parameters,
              referrer: originalCartItem.referrer,
              recommender_model_name: null,
              pay_in_installments: originalCartItem.pay_in_installments,
              force_new_subscription: originalCartItem.force_new_subscription,
              accepted_offer: {
                id: currentOffer.id,
                original_product_id: originalCartItem.product.id,
                discount: currentOffer.discount,
              },
            },
          ],
        };
      }
    } else if (currentOffer?.type === "upsell") {
      return {
        ...cartForm.data.cart,
        items: [
          ...cartForm.data.cart.items.filter((item) => item !== currentOffer.item),
          {
            ...currentOffer.item,
            option_id: currentOffer.offeredOption.id,
            price:
              currentOffer.item.product.price_cents +
              computeOptionPrice(currentOffer.offeredOption, currentOffer.item.recurrence),
            accepted_offer: {
              id: currentOffer.id,
              original_product_id: currentOffer.item.product.id,
              original_variant_id: currentOffer.item.option_id,
            },
          },
        ],
      };
    }
    return cartForm.data.cart;
  };

  return (
    <StateContext.Provider value={reducer}>
      {/* Unlayered seller styles override the stock values declared in `@layer base`. */}
      {checkoutStyle ? (
        <Head>
          <style>{`${checkoutStyle.css}\n${getCheckoutIndicatorCss(checkoutStyle.theme)}`}</style>
        </Head>
      ) : null}
      {redirecting ? null : results ? (
        (!user && results.every(({ result }) => result.success && result.content_url != null)) ||
        results.some(
          ({ result }) => result.success && result.bundle_products?.length && result.test_purchase_notice,
        ) ? (
          <TemporaryLibrary results={results} canBuyerSignUp={canBuyerSignUp} />
        ) : (
          <Receipt results={results} discoverUrl={discover_url} canBuyerSignUp={canBuyerSignUp} />
        )
      ) : (
        <CheckoutThemeProvider
          value={{
            theme: checkoutStyle?.theme ?? null,
            stripe_fonts_css_source: props.stripe_fonts_css_source,
          }}
        >
          <Checkout
            discoverUrl={discover_url}
            cart={cartForm.data.cart}
            updateCart={(updated) => cartForm.setData((prev) => ({ cart: { ...prev.cart, ...updated } }))}
            recommendedProducts={props.recommended_products ?? null}
          />
        </CheckoutThemeProvider>
      )}
      {currentOffer && surchargesIfAccepted ? (
        <Modal open onClose={completeOffer} title={currentOffer.text}>
          {currentOffer.type === "cross-sell" ? (
            <CrossSellModal
              crossSell={currentOffer}
              accept={acceptOffer}
              decline={completeOffer}
              cart={getCartIfAccepted()}
            />
          ) : (
            <UpsellModal cart={cartForm.data.cart} upsell={currentOffer} accept={acceptOffer} decline={completeOffer} />
          )}
        </Modal>
      ) : null}
      <Modal
        open={showLargeTipConfirmation}
        onClose={() => {
          setShowLargeTipConfirmation(false);
          dispatch({ type: "cancel" });
        }}
        title="Confirm tip amount"
        footer={
          <>
            <Button
              onClick={() => {
                setShowLargeTipConfirmation(false);
                dispatch({ type: "cancel" });
              }}
            >
              Edit tip
            </Button>
            <Button
              color="primary"
              onClick={() => {
                largeTipConfirmedRef.current = true;
                setShowLargeTipConfirmation(false);
              }}
            >
              Yes, leave tip
            </Button>
          </>
        }
      >
        <p>
          You're about to leave a tip of{" "}
          {listedCurrency
            ? formatPresentmentCents(listedTipCents, listedCurrency)
            : formatCheckoutPrice(computeTip(state), buyerCurrencyDisplay, {
                usdSymbolFormat: "short",
                noCentsIfWhole: true,
              })}{" "}
          on a{" "}
          {listedCurrency
            ? formatPresentmentCents(listedProductTotalCents, listedCurrency)
            : formatCheckoutPrice(getTotalPriceFromProducts(state), buyerCurrencyDisplay, {
                usdSymbolFormat: "short",
                noCentsIfWhole: true,
              })}{" "}
          purchase. Are you sure?
        </p>
      </Modal>
      <Modal
        open={duplicatePurchaseConfirmation !== null}
        onClose={() => {
          setDuplicatePurchaseConfirmation(null);
          dispatch({ type: "cancel" });
        }}
        title="You already own this"
        footer={
          <>
            <Button
              onClick={() => {
                setDuplicatePurchaseConfirmation(null);
                dispatch({ type: "cancel" });
              }}
            >
              Cancel
            </Button>
            <Button
              color="primary"
              onClick={() => {
                if (duplicatePurchaseConfirmation)
                  for (const uid of duplicatePurchaseConfirmation.uids)
                    confirmedDuplicatePurchaseUidsRef.current.add(uid);
                setDuplicatePurchaseConfirmation(null);
              }}
            >
              Buy again
            </Button>
          </>
        }
      >
        <p>
          You already paid for {duplicatePurchaseConfirmation?.productNames.join(", ") ?? ""}. Do you want to buy{" "}
          {(duplicatePurchaseConfirmation?.productNames.length ?? 0) > 1 ? "them" : "it"} again?
        </p>
      </Modal>
    </StateContext.Provider>
  );
};

CheckoutIndexPage.loggedInUserLayout = true;

export default CheckoutIndexPage;
