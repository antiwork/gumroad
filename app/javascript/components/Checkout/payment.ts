import { enableMapSet, produce } from "immer";
import groupBy from "lodash/groupBy";
import * as React from "react";

import { getSurcharges, SurchargesResponse } from "$app/data/customer_surcharge";
import { PurchasePaymentMethod } from "$app/data/purchase";
import { SavedCreditCard } from "$app/parsers/card";
import { CustomFieldDescriptor, ProductNativeType } from "$app/parsers/product";
import { assert } from "$app/utils/assert";
import { isValidEmail } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Creator } from "$app/components/Checkout/cartState";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

enableMapSet();

export type PaymentMethodType = "paypal" | "stripePaymentRequest" | "card";
export type PaymentMethod = { type: PaymentMethodType; button: React.ReactElement };

export type Product = {
  permalink: string;
  name: string;
  creator: Creator;
  quantity: number;
  price: number;
  payInInstallments: boolean;
  requireShipping: boolean;
  customFields: CustomFieldDescriptor[];
  bundleProductCustomFields: { product: { id: string; name: string }; customFields: CustomFieldDescriptor[] }[];
  supportsPaypal: "native" | "braintree" | null;
  testPurchase: boolean;
  requirePayment: boolean;
  hasFreeTrial: boolean;
  hasTippingEnabled: boolean;
  canGift: boolean;
  nativeType: ProductNativeType;
  subscription_id?: string;
  recommended_by?: string | null;
  shippableCountryCodes: string[];
};

export type Gift =
  | { type: "normal"; email: string; note: string }
  | { type: "anonymous"; id: string; name: string; note: string };

export type Tip = { type: "percentage"; percentage: number } | { type: "fixed"; amount: number | null };

export type State = {
  products: Product[];
  countries: Record<string, string>;
  usStates: string[];
  caProvinces: string[];
  tipOptions: number[];
  country: string;
  email: string;
  vatId: string;
  fullName: string;
  address: string;
  city: string;
  state: string;
  zipCode: string;
  saveAddress: boolean;
  gift: Gift | null;
  customFieldValues: Record<string, string>;
  surcharges:
    | { type: "error" | "pending" }
    | { type: "loading"; abort: () => void }
    | { type: "loaded"; result: SurchargesResponse };
  availablePaymentMethods: PaymentMethod[];
  paymentMethod: PaymentMethodType;
  savedCreditCard: SavedCreditCard | null;
  status:
    | { type: "input"; errors: Set<string> }
    | { type: "offering" }
    | { type: "validating" }
    | { type: "starting" }
    | { type: "captcha"; paymentMethod: PurchasePaymentMethod }
    | { type: "finished"; recaptchaResponse?: string; paymentMethod: PurchasePaymentMethod };
  payLabel?: string;
  recaptchaKey: string | null;
  paypalClientId?: string;
  tip: Tip;
  warning?: string | null;
  emailTypoSuggestion: string | null;
  acknowledgedEmails: Set<string>;
  requireEmailTypoAcknowledgment: boolean;
};

export const addressFields = ["address", "city", "state", "zipCode", "fullName", "country"] as const;

type SimpleValue =
  | "country"
  | "email"
  | "vatId"
  | "fullName"
  | "address"
  | "city"
  | "state"
  | "zipCode"
  | "saveAddress"
  | "paymentMethod"
  | "gift"
  | "payLabel"
  | "warning"
  | "tip"
  | "emailTypoSuggestion";

type PublicAction =
  | ({ type: "set-value" } & Partial<{ [key in SimpleValue]?: State[key] | undefined }>)
  | { type: "set-custom-field"; key: string; value: string }
  | { type: "add-payment-method"; paymentMethod: PaymentMethod }
  | { type: "offer" }
  | { type: "validate" }
  | { type: "start-payment" }
  | { type: "set-recaptcha-response"; recaptchaResponse?: string }
  | { type: "set-payment-method"; paymentMethod: PurchasePaymentMethod }
  | { type: "acknowledge-email-typo"; email: string }
  | {
      type: "update-products";
      products: Product[];
      surcharges?: SurchargesResponse;
    }
  | { type: "cancel" };

type Action = PublicAction | ({ type: "set-value" } & Partial<State>);

export function usePayLabel() {
  const [state] = useState();
  return isProcessing(state) ? "Processing..." : (state.payLabel ?? (requiresPayment(state) ? "Pay" : "Get"));
}

export function requiresPayment(state: State) {
  return getTotalPrice(state) !== 0 || state.products.some((item) => item.requirePayment);
}

export function requiresReusablePaymentMethod(state: State) {
  return (
    new Set(state.products.map((product) => product.creator.id)).size > 1 ||
    !!state.products[0]?.subscription_id ||
    state.products[0]?.nativeType === "commission"
  );
}

export function isProcessing(state: State) {
  return state.status.type !== "input";
}

export function isSubmitDisabled(state: State) {
  const emailTypoBlocking = state.requireEmailTypoAcknowledgment && state.emailTypoSuggestion !== null;
  return isProcessing(state) || state.surcharges.type !== "loaded" || emailTypoBlocking;
}

export const getTotalPriceFromProducts = (state: State) => state.products.reduce((sum, item) => sum + item.price, 0);

export function isTippingEnabled(state: State) {
  return (
    state.products.every((product) => product.hasTippingEnabled) &&
    !state.products.every((product) => product.nativeType === "coffee")
  );
}

export function computeTip(state: State) {
  if (!isTippingEnabled(state)) return 0;
  if (state.tip.type === "fixed") {
    return state.tip.amount ?? 0;
  }
  return Math.round((state.tip.percentage / 100) * getTotalPriceFromProducts(state));
}

export function computeTipForPrice(state: State, price: number, permalink: string | undefined = undefined) {
  if (!isTippingEnabled(state)) return null;
  if (state.tip.type === "fixed") {
    const totalPrice = getTotalPriceFromProducts(state);
    if (totalPrice === 0) {
      return computeTipForFreeCart(state, permalink);
    }

    return Math.round((state.tip.amount ?? 0) * (price / totalPrice));
  }

  return Math.round((state.tip.percentage / 100) * price);
}

function computeTipForFreeCart(state: State, permalink?: string): number {
  if (state.tip.type !== "fixed" || !state.tip.amount) return 0;
  // TODO (techdebt): Replace lodash `groupBy` with https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/groupBy
  // when project upgrades to https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-7.html#support-for---target-es2024-and---lib-es2024
  const creatorGroups = groupBy(state.products, (product) => product.creator.id);
  if (Object.values(creatorGroups).some((products) => products[0]?.permalink === permalink)) {
    return Math.round(state.tip.amount / Object.keys(creatorGroups).length);
  }
  return 0;
}

export function getTotalPrice(state: State) {
  return state.surcharges.type === "loaded"
    ? state.surcharges.result.subtotal + state.surcharges.result.tax_cents + state.surcharges.result.shipping_rate_cents
    : null;
}

export function getCustomFieldKey(
  field: CustomFieldDescriptor,
  product: { permalink: string; bundleProductId?: string | null },
) {
  return field.collect_per_product ? `${product.permalink}-${product.bundleProductId ?? ""}-${field.id}` : field.id;
}

export const hasShipping = (state: State) => state.products.some((item) => item.requireShipping);

export const getErrors = (state: State) => (state.status.type === "input" ? state.status.errors : new Set());

export const loadSurcharges = (state: State) => {
  const isGift = state.gift !== null;

  return getSurcharges({
    products: state.products.map((item) => ({
      permalink: item.permalink,
      quantity: item.quantity,
      price:
        item.hasFreeTrial && !isGift
          ? 0
          : Math.round(item.price + (computeTipForPrice(state, item.price, item.permalink) ?? 0)),
      subscription_id: item.subscription_id,
      recommended_by: item.recommended_by,
    })),
    country: state.country,
    state: state.state,
    vat_id: state.vatId,
    postal_code: state.zipCode,
  });
};

export function createReducer(initial: {
  countries: Record<string, string>;
  usStates: string[];
  caProvinces: string[];
  tipOptions: number[];
  defaultTipOption: number;
  country: string | null;
  email: string;
  state: string | null;
  address: { street: string | null; city: string | null; zip: string | null } | null;
  savedCreditCard: SavedCreditCard | null;
  products: Product[];
  fullName?: string;
  payLabel?: string;
  recaptchaKey: string | null;
  paypalClientId: string;
  gift: Gift | null;
  requireEmailTypoAcknowledgment: boolean;
}): readonly [State, React.Dispatch<PublicAction>] {
  const url = new URL(useOriginalLocation());
  function validatePaymentMethodIndependentFields(state: State) {
    const errors = new Set<string>();
    const customFields = state.products.flatMap(({ permalink, customFields, bundleProductCustomFields }) => [
      ...customFields.map((field) => ({ ...field, key: getCustomFieldKey(field, { permalink }) })),
      ...bundleProductCustomFields.flatMap(({ product, customFields }) =>
        customFields.map((field) => ({
          ...field,
          key: getCustomFieldKey(field, { permalink, bundleProductId: product.id }),
        })),
      ),
    ]);
    for (const field of customFields) {
      if ((field.type === "terms" || field.required) && !state.customFieldValues[field.key])
        errors.add(`customFields.${field.key}`);
    }
    if (isTippingEnabled(state) && state.tip.type === "fixed" && state.tip.amount === null) errors.add("tip");
    if (
      requiresPayment(state) &&
      state.paymentMethod !== "stripePaymentRequest" &&
      !hasShipping(state) &&
      state.country === "US" &&
      !state.zipCode
    )
      errors.add("zipCode");
    if (state.gift?.type === "normal" && !isValidEmail(state.gift.email)) errors.add("gift");
    return errors;
  }
  const reducer = React.useReducer(
    produce((state: State, action: Action) => {
      switch (action.type) {
        case "set-value":
          if (
            ("country" in action && action.country !== state.country) ||
            ("zipCode" in action &&
              action.zipCode !== state.zipCode &&
              state.country === "US" &&
              action.zipCode?.length === 5) ||
            ("state" in action && action.state !== state.state && state.country === "CA") ||
            ("vatId" in action && action.vatId !== state.vatId) ||
            ("gift" in action && action.gift?.type !== state.gift?.type) ||
            "products" in action ||
            "tip" in action
          ) {
            if (state.surcharges.type === "loading") state.surcharges.abort();
            state.surcharges = { type: "pending" };
          }
          if (state.status.type === "input") {
            for (const key in action) state.status.errors.delete(key);
          }
          if ("email" in action && action.email !== state.email) {
            state.emailTypoSuggestion = null;
          }
          Object.assign(state, action);
          break;
        case "set-custom-field":
          if (state.status.type !== "input") return;
          state.customFieldValues[action.key] = action.value;
          state.status.errors.delete(`customFields.${action.key}`);
          break;
        case "add-payment-method":
          if (!state.availablePaymentMethods.some((method) => method.type === action.paymentMethod.type))
            state.availablePaymentMethods.push(action.paymentMethod);
          break;
        case "offer": {
          const errors = validatePaymentMethodIndependentFields(state);
          state.status = errors.size ? { type: "input", errors } : { type: "offering" };
          break;
        }
        case "validate": {
          const errors = validatePaymentMethodIndependentFields(state);
          state.status = errors.size ? { type: "input", errors } : { type: "validating" };
          break;
        }
        case "start-payment":
          state.status = { type: "starting" };
          break;
        case "acknowledge-email-typo":
          state.acknowledgedEmails.add(action.email);
          state.emailTypoSuggestion = null;
          break;
        case "cancel":
          if (state.status.type === "input") return;
          state.status = { type: "input", errors: new Set() };
          break;
        case "set-recaptcha-response": {
          if (state.status.type !== "captcha") return;
          const recaptchaData = action.recaptchaResponse ? { recaptchaResponse: action.recaptchaResponse } : {};
          state.status = { ...state.status, type: "finished", ...recaptchaData };
          break;
        }
        case "set-payment-method": {
          if (state.status.type !== "starting") return;
          const errors = validatePaymentMethodIndependentFields(state);
          if (!isValidEmail(state.email)) errors.add("email");
          if (hasShipping(state)) {
            for (const field of addressFields) {
              if (!state[field]) errors.add(field);
            }
          }
          state.status = errors.size
            ? { type: "input", errors }
            : { type: "captcha", paymentMethod: action.paymentMethod };
          break;
        }
        case "update-products":
          state.products = action.products;
          if (state.surcharges.type === "loading") state.surcharges.abort();
          state.surcharges = action.surcharges ? { type: "loaded", result: action.surcharges } : { type: "pending" };
          break;
      }
    }),
    null,
    (): State => {
      const customFieldValues: Record<string, string> = {};
      for (const product of initial.products) {
        for (const customField of product.customFields) {
          const value = url.searchParams.get(customField.name);
          if (value) {
            customFieldValues[getCustomFieldKey(customField, product)] = value;
          }
        }
      }
      return {
        fullName: "",
        ...initial,
        country: initial.country ?? "US",
        vatId: "",
        address: initial.address?.street ?? "",
        city: initial.address?.city ?? "",
        state: initial.state ?? "",
        email: url.searchParams.get("email") ?? initial.email,
        zipCode: initial.address?.zip ?? "",
        customFieldValues,
        surcharges: { type: "pending" },
        saveAddress: !!initial.address,
        gift: initial.gift,
        paymentMethod: "card",
        tip: { type: "percentage", percentage: initial.defaultTipOption },
        status: { type: "input", errors: new Set() },
        availablePaymentMethods: [],
        emailTypoSuggestion: null,
        acknowledgedEmails: new Set<string>(),
        requireEmailTypoAcknowledgment: initial.requireEmailTypoAcknowledgment,
      };
    },
  );
  const [state, dispatch] = reducer;
  useRunOnce(() => {
    const url = new URL(window.location.href);
    const searchParams = new URLSearchParams([...url.searchParams].filter(([key]) => key === "_gl"));
    url.search = searchParams.toString();
    window.history.replaceState(window.history.state, "", url.toString());
  });

  const updateSurcharges = useDebouncedCallback(
    asyncVoid(async () => {
      if (!state.products.length) return;
      try {
        const abort = new AbortController();
        dispatch({ type: "set-value", surcharges: { type: "loading", abort: () => abort.abort() } });
        const result = await loadSurcharges(state);
        dispatch({ type: "set-value", surcharges: { type: "loaded", result } });
      } catch (e) {
        if (e instanceof AbortError) return;
        assertResponseError(e);
        dispatch({ type: "set-value", surcharges: { type: "error" } });
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    }),
    300,
  );
  React.useEffect(() => {
    if (state.surcharges.type === "pending") updateSurcharges();
  }, [state.surcharges]);

  return reducer;
}

export const StateContext = React.createContext<ReturnType<typeof createReducer> | null>(null);

export const useState = () => {
  const context = React.useContext(StateContext);
  assert(context != null, "Checkout StateContext is missing");
  return context;
};
