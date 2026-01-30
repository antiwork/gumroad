import { usePage } from "@inertiajs/react";
import { reverse } from "lodash-es";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SurchargesResponse } from "$app/data/customer_surcharge";
import { startOrderCreation } from "$app/data/order";
import { getPlugins, trackUserActionEvent, trackUserProductAction } from "$app/data/user_action_event";
import { SavedCreditCard } from "$app/parsers/card";
import { CardProduct, COMMISSION_DEPOSIT_PROPORTION, CustomFieldDescriptor } from "$app/parsers/product";
import { isOpenTuple } from "$app/utils/array";
import { assert } from "$app/utils/assert";
import { getIsSingleUnitCurrency } from "$app/utils/currency";
import { isValidEmail } from "$app/utils/email";
import { calculateFirstInstallmentPaymentPriceCents } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

import { Checkout } from "$app/components/Checkout";
import {
  CartItem,
  CartState,
  convertToUSD,
  findCartItem,
  getDiscountedPrice,
  ProductToAdd,
  CrossSell,
  saveCartState,
  newCartState,
} from "$app/components/Checkout/cartState";
import { CrossSellModal, UpsellModal, Result, OfferedUpsell } from "$app/components/Checkout/modals";
import {
  StateContext,
  createReducer,
  Product,
  loadSurcharges,
  requiresReusablePaymentMethod,
  Gift,
  getCustomFieldKey,
  computeTipForPrice,
} from "$app/components/Checkout/payment";
import { Receipt } from "$app/components/Checkout/Receipt";
import { TemporaryLibrary } from "$app/components/Checkout/TemporaryLibrary";
import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { computeOptionPrice } from "$app/components/Product/ConfigurationSelector";
import { showAlert } from "$app/components/server-components/Alert";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange, useOnChangeSync } from "$app/components/useOnChange";

const GUMROAD_PARAMS = [
  "product",
  "option",
  "recurrence",
  "quantity",
  "price",
  "recommended_by",
  "affiliate_id",
  "referrer",
  "rent",
  "recommender_model_name",
  "call_start_time",
  "pay_in_installments",
];

type Props = {
  discover_url: string;
  countries: Record<string, string>;
  us_states: string[];
  ca_provinces: string[];
  clear_cart: boolean;
  add_products: ProductToAdd[];
  gift: Gift | null;
  country: string | null;
  state: string | null;
  address: { street: string | null; city: string | null; zip: string | null } | null;
  saved_credit_card: SavedCreditCard | null;
  recaptcha_key: string | null;
  paypal_client_id: string;
  cart: CartState | null;
  max_allowed_cart_products: number;
  tip_options: number[];
  default_tip_option: number;
};

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

const addProduct = ({
  cart,
  product,
  url,
  referrer,
}: {
  cart: CartState;
  product: ProductToAdd;
  url: URL;
  referrer: string | null;
}) => {
  const existing = findCartItem(cart, product.product.permalink, product.option_id);

  const urlParameters: Record<string, string> = {};
  for (const [key, value] of url.searchParams.entries()) if (!GUMROAD_PARAMS.includes(key)) urlParameters[key] = value;

  const option = product.product.options.find(({ id }) => id === product.option_id);
  const newItem = {
    ...product,
    quantity: Math.min(
      product.quantity || 1,
      (option ? option.quantity_left : product.product.quantity_remaining) ?? Infinity,
    ),
    url_parameters: urlParameters,
    referrer: referrer || "direct",
    recommender_model_name: url.searchParams.get("recommender_model_name"),
  };
  if (existing) Object.assign(existing, newItem);
  else cart.items.unshift(newItem);
};

const CheckoutPage = () => {
  const {
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
    paypal_client_id,
    max_allowed_cart_products,
    tip_options,
    default_tip_option,
    ...props
  } = usePage<Props>().props;

  const user = useLoggedInUser();
  const email = props.cart?.email ?? user?.email ?? "";
  const [cart, setCart] = React.useState<CartState>(() => {
    const initialCart = clear_cart ? newCartState() : (props.cart ?? newCartState());
    const url = new URL(window.location.href);
    const urlReferrer = url.searchParams.get("referrer");
    const referrer = urlReferrer && decodeURIComponent(urlReferrer);
    const returnUrl = referrer || document.referrer;
    if (returnUrl) initialCart.returnUrl = returnUrl;

    const newAddProducts = add_products.filter(
      (product) => !findCartItem(initialCart, product.product.permalink, product.option_id),
    );
    if (initialCart.items.length + newAddProducts.length > max_allowed_cart_products) {
      showAlert(`You cannot add more than ${max_allowed_cart_products} products to the cart.`, "error");
      initialCart.items = initialCart.items.slice(0, max_allowed_cart_products);
      return initialCart;
    }

    if (add_products.length) {
      for (const product of reverse(add_products)) {
        addProduct({ cart: initialCart, product, url, referrer });
      }

      const creatorCarts = new Map<string, CartItem[]>();
      for (const item of initialCart.items) {
        startTrackingForSeller(item.product.creator.id, item.product.analytics);

        creatorCarts.set(item.product.creator.id, [...(creatorCarts.get(item.product.creator.id) ?? []), item]);
      }

      for (const [creatorId, creatorCart] of creatorCarts) {
        const products = creatorCart.map((item) => ({
          permalink: item.product.permalink,
          name: item.product.name,
          quantity: item.quantity,
          price: convertToUSD(item, getDiscountedPrice(initialCart, item).price) / 100.0,
        }));
        trackProductEvent(creatorId, {
          action: "begin_checkout",
          seller_id: creatorId,
          price: products.reduce((sum, { price, quantity }) => sum + price * quantity, 0),
          products,
        });
      }

      initialCart.rejectPppDiscount = false;
    }
    return initialCart;
  });
  const { require_email_typo_acknowledgment } = useFeatureFlags();
  const reducer = createReducer({
    country,
    email,
    address,
    countries,
    caProvinces: ca_provinces,
    usStates: us_states,
    tipOptions: tip_options,
    defaultTipOption: default_tip_option,
    savedCreditCard: saved_credit_card,
    state: addressState,
    products: getProducts(cart),
    recaptchaKey: recaptcha_key,
    paypalClientId: paypal_client_id,
    gift,
    requireEmailTypoAcknowledgment: require_email_typo_acknowledgment,
  });
  const [state, dispatch] = reducer;
  const [results, setResults] = React.useState<Result[] | null>(null);
  const [canBuyerSignUp, setCanBuyerSignUp] = React.useState(false);
  const [redirecting, setRedirecting] = React.useState(false);
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();
  const [recommendedProducts, setRecommendedProducts] = React.useState<CardProduct[] | null>(null);

  const completedOfferIds = React.useRef(new Set()).current;
  const [offers, setOffers] = React.useState<
    null | ((CrossSell & { type: "cross-sell" }) | (OfferedUpsell & { type: "upsell" }))[]
  >(null);
  const currentOffer = offers?.[0];

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

  const completeOffer = () => {
    if (!currentOffer) return;
    completedOfferIds.add(currentOffer.id);
    if (offers.length === 1) dispatch({ type: "validate" });
    setSurchargesIfAccepted(null);
    setOffers((prevOffers) => prevOffers?.slice(1) ?? prevOffers);
  };
  const acceptOffer = () => {
    const newCart = getCartIfAccepted();
    setCart(newCart);
    if (surchargesIfAccepted)
      dispatch({
        type: "update-products",
        products: getProducts(newCart),
        surcharges: surchargesIfAccepted,
      });
    completeOffer();
  };

  useOnChangeSync(() => {
    if (state.status.type !== "offering") return;
    const seenCrossSellIds = new Set();
    const newOffers = [
      ...cart.items
        .flatMap(({ product }) => product.cross_sells)
        .filter((crossSell) => {
          const seen = seenCrossSellIds.has(crossSell.id);
          seenCrossSellIds.add(crossSell.id);
          return (
            !completedOfferIds.has(crossSell.id) &&
            !seen &&
            !findCartItem(cart, crossSell.offered_product.product.permalink, crossSell.offered_product.option_id)
          );
        })
        .map((crossSell) => ({ type: "cross-sell", ...crossSell }) as const),
      ...cart.items.flatMap((item) => {
        const currentOption = item.product.options.find(({ id }) => id === item.option_id);
        const offeredOption = item.product.options.find(({ id }) => id === currentOption?.upsell_offered_variant_id);
        return item.product.upsell &&
          !completedOfferIds.has(item.product.upsell.id) &&
          offeredOption &&
          !findCartItem(cart, item.product.permalink, offeredOption.id)
          ? ({ type: "upsell", ...item.product.upsell, item, offeredOption } as const)
          : [];
      }),
    ];
    if (newOffers.length === 0) dispatch({ type: "validate" });
    setOffers(newOffers);
  }, [state.status.type]);

  function getProducts(state: CartState): Product[] {
    return state.items.map((item) => {
      const { price } = getDiscountedPrice(state, item);
      return {
        permalink: item.product.permalink,
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
        price: convertToUSD(item, price),
        payInInstallments: item.pay_in_installments,
        recommended_by: item.recommended_by,
        shippableCountryCodes: item.product.shippable_country_codes,
        nativeType: item.product.native_type,
        canGift: item.product.can_gift,
      };
    });
  }

  async function pay() {
    if (state.status.type !== "finished") return;
    try {
      await trackUserActionEvent("process_payment");
      if (user) {
        await Promise.all(
          cart.items.map((item) =>
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
        zipCode: state.zipCode,
        state: state.state,
        paymentMethod: state.status.paymentMethod,
        shippingInfo: cart.items.some((item) => item.product.require_shipping)
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
        lineItems: cart.items.map((item) => {
          const discounted = getDiscountedPrice(cart, item);

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

          const tipCents =
            item.pay_in_installments && item.product.installment_plan
              ? computeTipForPrice(state, discountedPriceTotal, item.product.permalink)
              : computeTipForPrice(state, discountedPriceToChargeNow, item.product.permalink);

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
              !cart.rejectPppDiscount &&
              discounted.discount?.type === "ppp" &&
              item.price !== 0,
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
            urlParameters: JSON.stringify(item.url_parameters),
            referrer: item.referrer,
          };
        }),
      };
      const result = await startOrderCreation(requestData);
      const results = Object.entries(result.lineItems).flatMap(([key, result]) => {
        const [permalink, optionId] = key.split(" ");
        const item = cart.items.find(
          (item) => item.product.permalink === permalink && item.option_id === (optionId || null),
        );
        return item ? { item, result } : [];
      });
      assert(isOpenTuple(results, 1), "startCartPayment returned empty results");

      const failedItems = cart.items.flatMap((item) => {
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
          results.every(({ result }) => result.success && result.content_url != null && !result.test_purchase_notice)
        )
          redirectTo = "library-page";
      }

      for (const { result, item } of results) {
        if (!result.success) continue;
        trackProductEvent(item.product.creator.id, {
          action: "purchased",
          seller_id: result.seller_id,
          permalink: result.permalink,
          purchase_external_id: result.id,
          currency: result.currency_type.toUpperCase(),
          product_name: result.name,
          value: result.non_formatted_price,
          valueIsSingleUnit: getIsSingleUnitCurrency(cast(result.currency_type)),
          quantity: result.quantity,
          tax: result.non_formatted_seller_tax_amount,
        });
        if (result.has_third_party_analytics && !redirectTo)
          addThirdPartyAnalytics({ permalink: result.permalink, location: "receipt", purchaseId: result.id });
      }

      setRedirecting(!!redirectTo);

      setCart({
        ...cart,
        items: failedItems,
        discountCodes: result.offerCodes.map((discountCode) => ({
          ...discountCode,
          fromUrl: cart.discountCodes.find(({ code }) => code === discountCode.code)?.fromUrl ?? false,
        })),
        rejectPppDiscount: false,
      });

      if (redirectTo === "content-page" && firstResult.success && firstResult.content_url) {
        const contentUrl = new URL(firstResult.content_url);
        if (firstResult.native_type === "coffee") contentUrl.searchParams.set("purchase_email", state.email);
        else contentUrl.searchParams.set("receipt", "true");
        window.location.href = contentUrl.toString();
      } else if (redirectTo === "library-page") {
        const purchases = results.flatMap(({ result }) => (result.success ? result.id : []));
        const libraryUrl = new URL(Routes.library_url());
        for (const purchase of purchases) libraryUrl.searchParams.append("purchase_id", purchase);
        window.location.href = libraryUrl.toString();
      }

      setResults(results);
      setCanBuyerSignUp(result.canBuyerSignUp);
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
      dispatch({ type: "cancel" });
    }
  }
  React.useEffect(() => void pay(), [state.status]);

  const debouncedSaveCartState = useDebouncedCallback(
    asyncVoid(async () => {
      try {
        await saveCartState(cart);
      } catch (e) {
        assertResponseError(e);
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    }),
    100,
  );
  React.useEffect(() => {
    debouncedSaveCartState();
    if (state.status.type === "input") {
      dispatch({ type: "update-products", products: getProducts(cart) });
    }
  }, [cart]);
  useOnChange(() => {
    if (state.email.trim() === "" || isValidEmail(state.email.trim())) {
      setCart((prev) => ({ ...prev, email: state.email.trim() }));
    }
  }, [state.email]);

  const getCartIfAccepted = () => {
    if (currentOffer?.type === "cross-sell") {
      const originalCartItems = cart.items.filter(({ product }) =>
        product.cross_sells.some(({ id }) => id === currentOffer.id),
      );
      const originalCartItem = originalCartItems[0];
      if (originalCartItem) {
        return {
          ...cart,
          items: [
            ...(currentOffer.replace_selected_products
              ? cart.items.filter((item) => !originalCartItems.includes(item))
              : cart.items),
            {
              ...currentOffer.offered_product,
              product: { ...currentOffer.offered_product.product, cross_sells: [] },
              quantity: 1,
              url_parameters: originalCartItem.url_parameters,
              referrer: originalCartItem.referrer,
              recommender_model_name: null,
              pay_in_installments: originalCartItem.pay_in_installments,
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
        ...cart,
        items: [
          ...cart.items.filter((item) => item !== currentOffer.item),
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
    return cart;
  };

  return (
    <StateContext.Provider value={reducer}>
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
        <Checkout
          discoverUrl={discover_url}
          cart={cart}
          setCart={setCart}
          recommendedProducts={recommendedProducts}
          setRecommendedProducts={setRecommendedProducts}
        />
      )}
      {currentOffer && surchargesIfAccepted ? (
        <Modal open onClose={completeOffer} title={currentOffer.text}>
          {currentOffer.type === "cross-sell" ? (
            <CrossSellModal crossSell={currentOffer} accept={acceptOffer} decline={completeOffer} cart={cart} />
          ) : (
            <UpsellModal cart={cart} upsell={currentOffer} accept={acceptOffer} decline={completeOffer} />
          )}
        </Modal>
      ) : null}
    </StateContext.Provider>
  );
};

CheckoutPage.loggedInUserLayout = true;
export default CheckoutPage;
