import { Apple, CreditCard, Google, Paypal } from "@boxicons/react";
import { loadScript as loadPaypal, PayPalNamespace } from "@paypal/paypal-js";
import { useStripe } from "@stripe/react-stripe-js";
import {
  CanMakePaymentResult,
  PaymentRequestPaymentMethodEvent,
  PaymentRequestShippingAddress,
  PaymentRequestShippingAddressEvent,
  StripeCardElement,
} from "@stripe/stripe-js";
import { DataCollector, PayPal } from "braintree-web";
import * as BraintreeClient from "braintree-web/client";
import * as BraintreeDataCollector from "braintree-web/data-collector";
import * as BraintreePaypal from "braintree-web/paypal";
import * as React from "react";

import { useBraintreeToken } from "$app/data/braintree_client_token_data";
import {
  createPaymentElementConfirmationToken,
  isWalletPaymentElementType,
  preparePaymentRequestPaymentMethodData,
} from "$app/data/card_payment_method_data";
import {
  getPaymentMethodResult,
  getPaymentRequestPaymentMethodResult,
  getReusablePaymentMethodResult,
  getReusablePaymentRequestPaymentMethodResult,
  SelectedPaymentMethod,
} from "$app/data/payment_method_result";
import { createBillingAgreement, createBillingAgreementToken } from "$app/data/paypal";
import { PurchasePaymentMethod } from "$app/data/purchase";
import { assert, assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { checkEmailForTypos as checkEmailForTyposUtil } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { persistAcknowledgedEmail } from "$app/components/Checkout/acknowledgedEmails";
import { getApplePayRecurringPaymentRequest } from "$app/components/Checkout/applePayRecurringPaymentRequest";
import { CreditCardInput, StripeElementsProvider } from "$app/components/Checkout/CreditCardInput";
import { CustomFields } from "$app/components/Checkout/CustomFields";
import { resolveHeldWalletPayment, type HeldWalletPayment } from "$app/components/Checkout/heldWalletPayment";
import {
  addressFields,
  canUseStripePaymentElement,
  canUseStripePaymentElementClientConfirm,
  getErrors,
  getStripePaymentElementAmount,
  getStripePaymentElementMountCurrency,
  getChargeTodayPrice,
  hasShipping,
  isCardReadyToPay,
  isProcessing,
  isSubmitDisabled,
  PaymentMethodType,
  requiresReusablePaymentMethodForCardCollection,
  requiresPayment,
  requiresReusablePaymentMethod,
  usePayLabel,
  useState,
} from "$app/components/Checkout/payment";
import { getPaymentElementApplePayOption } from "$app/components/Checkout/paymentElementApplePayOption";
import { PaymentElementController, PaymentElementInput } from "$app/components/Checkout/PaymentElementInput";
import { applyWalletBillingAddressToCheckout } from "$app/components/Checkout/walletBillingAddress";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover, PopoverAnchor, PopoverContent } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Radio } from "$app/components/ui/Radio";
import { Select } from "$app/components/ui/Select";
import { useIsDarkTheme } from "$app/components/useIsDarkTheme";
import { useOnChangeSync } from "$app/components/useOnChange";
import {
  RECAPTCHA_UNAVAILABLE_MESSAGE,
  RecaptchaCancelledError,
  RecaptchaUnavailableError,
  useRecaptcha,
} from "$app/components/useRecaptcha";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { useRunOnce } from "$app/components/useRunOnce";

import { Product } from "./cartState";

const CountryInput = () => {
  const [state, dispatch] = useState();
  const uid = React.useId();
  const shippingCountryCodes = React.useMemo(
    () =>
      new Set<string>(
        state.products.filter((product) => product.requireShipping).flatMap((product) => product.shippableCountryCodes),
      ),
    [state.products],
  );

  React.useEffect(() => {
    if (!shippingCountryCodes.has(state.country)) {
      const result = shippingCountryCodes.values().next();
      if (!result.done) dispatch({ type: "set-value", country: result.value });
    }
  }, [state.country, shippingCountryCodes]);

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label htmlFor={`${uid}country`}>Country</Label>
      </FieldsetTitle>
      <Select
        id={`${uid}country`}
        value={state.country}
        onChange={(e) =>
          dispatch({
            type: "set-value",
            country: e.target.value,
            state: e.target.value === "CA" ? state.caProvinces[0] : state.state,
          })
        }
        disabled={isProcessing(state)}
      >
        {(shippingCountryCodes.size > 0 ? [...shippingCountryCodes] : Object.keys(state.countries)).map(
          (countryCode) => (
            <option key={state.countries[countryCode]} value={countryCode}>
              {state.countries[countryCode]}
            </option>
          ),
        )}
      </Select>
    </Fieldset>
  );
};

const StateInput = () => {
  const [state, dispatch] = useState();
  const uid = React.useId();
  const errors = getErrors(state);

  let stateLabel: string;
  let states: string[] | null = null;
  switch (state.country) {
    case "US":
      stateLabel = "State";
      states = state.usStates;
      break;
    case "PH":
      stateLabel = "State";
      break;
    case "CA":
      stateLabel = "Province";
      states = state.caProvinces;
      break;
    default:
      stateLabel = "County";
      break;
  }

  return (
    <Fieldset state={errors.has("state") ? "danger" : undefined}>
      <FieldsetTitle>
        <Label htmlFor={`${uid}state`}>{stateLabel}</Label>
      </FieldsetTitle>
      {(state.country === "US" || state.country === "CA") && states !== null ? (
        <Select
          id={`${uid}state`}
          value={state.state}
          onChange={(e) => dispatch({ type: "set-value", state: e.target.value })}
          disabled={isProcessing(state)}
        >
          {states.map((state) => (
            <option key={state} value={state}>
              {state}
            </option>
          ))}
        </Select>
      ) : (
        <Input
          id={`${uid}state`}
          type="text"
          aria-invalid={errors.has("state")}
          disabled={isProcessing(state)}
          value={state.state}
          onChange={(e) => dispatch({ type: "set-value", state: e.target.value })}
        />
      )}
    </Fieldset>
  );
};

const ZipCodeInput = () => {
  const [state, dispatch] = useState();
  const uid = React.useId();
  const errors = getErrors(state);
  const label = state.country === "US" || state.country === "PH" ? "ZIP code" : "Postal";

  return (
    <Fieldset state={errors.has("zipCode") ? "danger" : undefined}>
      <FieldsetTitle>
        <Label htmlFor={`${uid}zipCode`}>{label}</Label>
      </FieldsetTitle>
      <Input
        id={`${uid}zipCode`}
        type="text"
        aria-invalid={errors.has("zipCode")}
        value={state.zipCode}
        onChange={(e) => dispatch({ type: "set-value", zipCode: e.target.value })}
        disabled={isProcessing(state)}
      />
    </Fieldset>
  );
};

const SharedInputs = ({ className }: { className?: string | undefined }) => {
  const uid = React.useId();
  const loggedInUser = useLoggedInUser();
  const [state, dispatch] = useState();
  const errors = getErrors(state);

  const checkForEmailTypos = () => {
    if (state.acknowledgedEmails.has(state.email)) return;
    checkEmailForTyposUtil(state.email, (suggestion) => {
      dispatch({ type: "set-value", emailTypoSuggestion: suggestion.full });
    });
  };

  const rejectEmailTypoSuggestion = () => {
    // Persist here rather than in the reducer so the reducer stays free of side effects.
    persistAcknowledgedEmail(state.email);
    dispatch({ type: "acknowledge-email-typo", email: state.email });
  };

  const acceptEmailTypoSuggestion = () => {
    if (!state.emailTypoSuggestion) return;
    persistAcknowledgedEmail(state.emailTypoSuggestion);
    dispatch({ type: "set-value", email: state.emailTypoSuggestion });
    dispatch({ type: "acknowledge-email-typo", email: state.emailTypoSuggestion });
  };

  const [showVatIdInput, setShowVatIdInput] = React.useState(false);
  React.useEffect(
    () =>
      setShowVatIdInput((prevShowVatIdInput) =>
        state.surcharges.type === "loaded"
          ? state.surcharges.result.has_vat_id_input || state.surcharges.result.vat_id_valid
          : prevShowVatIdInput,
      ),
    [state.surcharges],
  );

  let vatLabel;
  switch (state.country) {
    case "AE":
    case "BH":
      vatLabel = "Business TRN ID (optional)";
      break;
    case "AU":
      vatLabel = "Business ABN ID (optional)";
      break;
    case "BY":
      vatLabel = "Business UNP ID (optional)";
      break;
    case "CL":
      vatLabel = "Business RUT ID (optional)";
      break;
    case "CO":
      vatLabel = "Business NIT ID (optional)";
      break;
    case "CR":
      vatLabel = "Business CPJ ID (optional)";
      break;
    case "EC":
      vatLabel = "Business RUC ID (optional)";
      break;
    case "EG":
      vatLabel = "Business TN ID (optional)";
      break;
    case "GE":
    case "KZ":
    case "MA":
    case "TH":
      vatLabel = "Business TIN ID (optional)";
      break;
    case "KE":
      vatLabel = "Business KRA PIN (optional)";
      break;
    case "KR":
      vatLabel = "Business BRN ID (optional)";
      break;
    case "RU":
      vatLabel = "Business INN ID (optional)";
      break;
    case "RS":
      vatLabel = "Business PIB ID (optional)";
      break;
    case "SG":
    case "IN":
      vatLabel = "Business GST ID (optional)";
      break;
    case "TR":
      vatLabel = "Business VKN ID (optional)";
      break;
    case "UA":
      vatLabel = "Business EDRPOU ID (optional)";
      break;
    case "CA":
      vatLabel = "Business QST ID (optional)";
      break;
    case "IS":
      vatLabel = "Business VSK ID (optional)";
      break;
    case "MX":
      vatLabel = "Business RFC ID (optional)";
      break;
    case "MY":
      vatLabel = "Business SST ID (optional)";
      break;
    case "NG":
      vatLabel = "Business FIRS TIN (optional)";
      break;
    case "NO":
      vatLabel = "Business MVA ID (optional)";
      break;
    case "OM":
      vatLabel = "Business VAT Number (optional)";
      break;
    case "NZ":
      vatLabel = "Business IRD ID (optional)";
      break;
    case "JP":
      vatLabel = "Business CN ID (optional)";
      break;
    case "VN":
      vatLabel = "Business MST ID (optional)";
      break;
    case "TZ":
      vatLabel = "Business TRA TIN (optional)";
      break;
    default:
      vatLabel = "Business VAT ID (optional)";
      break;
  }

  const showCountryInput = !(hasShipping(state) || !requiresPayment(state));
  const showFullNameInput = requiresPayment(state) && !hasShipping(state);

  return (
    <Card>
      <div className={className}>
        <div className="flex grow flex-col gap-4">
          <h4 className="text-base sm:text-lg">Contact information</h4>
          <Fieldset state={errors.has("email") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}email`}>Email address</Label>
            </FieldsetTitle>
            <div className="relative inline-block w-full">
              <Popover open={!!state.emailTypoSuggestion}>
                <PopoverAnchor>
                  <Input
                    id={`${uid}email`}
                    type="email"
                    aria-invalid={errors.has("email")}
                    value={state.email}
                    onChange={(evt) => dispatch({ type: "set-value", email: evt.target.value.toLowerCase() })}
                    disabled={(loggedInUser && loggedInUser.email !== null) || isProcessing(state)}
                    onBlur={checkForEmailTypos}
                  />
                </PopoverAnchor>
                {/* Open upward: the pay/download button sits right below the email field, and a
                    downward popover covers it, blocking the purchase until the buyer answers. */}
                <PopoverContent className="grid gap-2" matchTriggerWidth side="top">
                  <div>Did you mean {state.emailTypoSuggestion}?</div>
                  <div className="flex gap-2">
                    <Button onClick={rejectEmailTypoSuggestion}>No</Button>
                    <Button onClick={acceptEmailTypoSuggestion}>Yes</Button>
                  </div>
                </PopoverContent>
              </Popover>
            </div>
          </Fieldset>
          {showFullNameInput ? (
            <Fieldset state={errors.has("fullName") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}fullName`}>Full name</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}fullName`}
                type="text"
                aria-invalid={errors.has("fullName")}
                value={state.fullName}
                onChange={(e) => dispatch({ type: "set-value", fullName: e.target.value })}
                disabled={isProcessing(state)}
              />
            </Fieldset>
          ) : null}
          {showCountryInput ? (
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(min((20rem - 100%) * 1000, 100%), 1fr))",
                gap: "var(--spacer-4)",
              }}
            >
              <CountryInput />
              {state.country === "US" ? <ZipCodeInput /> : null}
              {state.country === "CA" ? <StateInput /> : null}
            </div>
          ) : null}
          {showVatIdInput ? (
            <Fieldset state={errors.has("vatId") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}vatId`}>{vatLabel}</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}vatId`}
                type="text"
                value={state.vatId}
                onChange={(e) => dispatch({ type: "set-value", vatId: e.target.value })}
                disabled={isProcessing(state)}
              />
            </Fieldset>
          ) : null}
        </div>
      </div>
    </Card>
  );
};

const PaymentMethodRadioRow = ({
  paymentMethod,
  label,
  icon,
}: {
  paymentMethod: PaymentMethodType;
  label: string;
  icon: React.ReactNode;
}) => {
  const uid = React.useId();
  const [state, dispatch] = useState();
  const selected = state.paymentMethod === paymentMethod;
  const disabled = !selected && isProcessing(state);

  return (
    <Label
      className={classNames(
        "flex cursor-pointer items-center gap-3 border-b-0 p-4",
        selected ? "bg-body" : "",
        disabled && "cursor-not-allowed opacity-50",
      )}
      htmlFor={`${uid}-${paymentMethod}`}
    >
      <Radio
        id={`${uid}-${paymentMethod}`}
        name={`${uid}-payment-method`}
        checked={selected}
        onChange={() => {
          if (paymentMethod !== state.paymentMethod) {
            dispatch({ type: "set-value", paymentMethod });
          }
        }}
        disabled={disabled}
      />
      {icon}
      <span className="font-medium">{label}</span>
    </Label>
  );
};

const useFail = () => {
  const [_, dispatch] = useState();
  return () => {
    showAlert("Sorry, something went wrong. You were not charged.", "error");
    dispatch({ type: "cancel" });
  };
};

const CustomerDetails = ({ className }: { className?: string }) => {
  const isLoggedIn = !!useLoggedInUser();
  const [state, dispatch] = useState();
  const uid = React.useId();
  const errors = getErrors(state);

  React.useEffect(() => {
    // Shipping addresses used to be checked against a third-party address-verification service
    // here (with a suggested-correction dialog); that integration was removed, so validation now
    // proceeds straight to payment with the address exactly as the buyer entered it.
    if (state.status.type !== "validating") return;
    dispatch({ type: "start-payment" });
  }, [state.status.type]);

  return (
    <>
      <SharedInputs className={className} />
      {hasShipping(state) ? (
        <Card>
          <div className={className}>
            <div className="flex grow flex-col gap-4">
              <h4 className="text-base sm:text-lg">Shipping information</h4>
              <Fieldset state={errors.has("fullName") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}fullName`}>Full name</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}fullName`}
                  type="text"
                  aria-invalid={errors.has("fullName")}
                  disabled={isProcessing(state)}
                  value={state.fullName}
                  onChange={(e) => dispatch({ type: "set-value", fullName: e.target.value })}
                />
              </Fieldset>
              <Fieldset state={errors.has("address") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}address`}>Street address</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}address`}
                  type="text"
                  aria-invalid={errors.has("address")}
                  disabled={isProcessing(state)}
                  value={state.address}
                  onChange={(e) => dispatch({ type: "set-value", address: e.target.value })}
                />
              </Fieldset>
              <div style={{ display: "grid", gridAutoFlow: "column", gridAutoColumns: "1fr", gap: "var(--spacer-2)" }}>
                <Fieldset state={errors.has("city") ? "danger" : undefined}>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}city`}>City</Label>
                  </FieldsetTitle>
                  <Input
                    id={`${uid}city`}
                    type="text"
                    aria-invalid={errors.has("city")}
                    disabled={isProcessing(state)}
                    value={state.city}
                    onChange={(e) => dispatch({ type: "set-value", city: e.target.value })}
                  />
                </Fieldset>
                <StateInput />
                <ZipCodeInput />
              </div>
              <CountryInput />
              {isLoggedIn ? (
                <Label>
                  <Checkbox
                    title="Save shipping address to account"
                    checked={state.saveAddress}
                    onChange={(e) => dispatch({ type: "set-value", saveAddress: e.target.checked })}
                    disabled={isProcessing(state)}
                  />
                  Save address for future purchases
                </Label>
              ) : null}
            </div>
          </div>
        </Card>
      ) : null}
      {state.warning ? (
        <Card>
          <div className={className}>
            <Alert role="status" variant="warning" className="grow">
              {state.warning}
            </Alert>
          </div>
        </Card>
      ) : null}
    </>
  );
};

// The shared wallet billing-address tax-location logic lives in walletBillingAddress.ts —
// both wallet surfaces (Payment Request Button and Payment Element wallets) must go through
// applyWalletBillingAddressToCheckout so the tax-critical rules can never drift between them.

const PayButton = ({
  className,
  isTestPurchase,
  card = true,
}: {
  className?: string;
  isTestPurchase?: boolean;
  card?: boolean;
}) => {
  const [state, dispatch] = useState();
  const payLabel = usePayLabel();

  if (state.paymentMethod === "paypal" || state.paymentMethod === "stripePaymentRequest") return null;

  const content = (
    <div className={`${className} flex-col !items-stretch gap-4`}>
      <Button
        color="primary"
        onClick={() => dispatch({ type: "offer" })}
        disabled={isSubmitDisabled(state)}
        className="w-full"
      >
        {payLabel}
      </Button>
      {isTestPurchase ? (
        <Alert variant="info">
          This will be a test purchase as you are the creator of at least one of the products. Your payment method will
          not be charged.
        </Alert>
      ) : null}
    </div>
  );

  if (card) {
    return <Card>{content}</Card>;
  }

  return content;
};

const CreditCardContent = ({
  onPaymentElementReadyChange,
  walletClickSubmitRef,
  flatPaymentMethodsList = false,
  paymentMethodsAppendix,
}: {
  onPaymentElementReadyChange?: ((ready: boolean) => void) | undefined;
  // Set by this component to a function the card Pay button calls SYNCHRONOUSLY in its click
  // handler. Safari only opens the Apple Pay sheet inside a user-activation window, and Stripe's
  // deferred flow requires elements.submit() to run directly in the pay click for wallet
  // payments (the sheet itself opens later, at createPaymentMethod/createConfirmationToken).
  // Checkout reaches tokenization through async effects several ticks after the click, so the
  // click handler triggers the submit here and tokenization reuses the in-flight promise.
  walletClickSubmitRef?: React.MutableRefObject<(() => void) | null> | undefined;
  // The payment_element_wallets flat layout (see PaymentMethodsSection): this component stays
  // mounted even while PayPal is checkout's selected payment method (the element's accordion IS
  // the payment-method list, and unmounting it would wipe entered card details). Interacting
  // with the element (focusing a field or picking one of its rows) re-selects the card/wallet
  // lane, and the save-card checkbox only shows while that lane is selected.
  flatPaymentMethodsList?: boolean;
  // Rendered directly below the Payment Element in the flat layout — the PayPal row, styled to
  // read as one more accordion item so Card / Apple Pay / PayPal form a single flat list.
  paymentMethodsAppendix?: React.ReactNode;
}) => {
  const [state, dispatch] = useState();
  const fail = useFail();
  const isLoggedIn = !!useLoggedInUser();

  const cardElementRef = React.useRef<StripeCardElement | null>(null);
  const paymentElementRef = React.useRef<PaymentElementController | null>(null);
  const [paymentElementReady, setPaymentElementReady] = React.useState(false);
  const [useSavedCard, setUseSavedCard] = React.useState(!!state.savedCreditCard);
  const [keepOnFile, setKeepOnFile] = React.useState(isLoggedIn);

  // Mirror the save-card intent into checkout state: saving a card charges through the
  // canonical path in PR 1, so the cart must stop displaying buyer-currency totals.
  const willSaveCard = !useSavedCard && isLoggedIn && keepOnFile;
  React.useEffect(() => {
    dispatch({ type: "set-value", willSaveCard });
  }, [dispatch, willSaveCard]);

  const [cardError, setCardError] = React.useState(false);

  // The in-flight elements.submit() started synchronously by the pay-button click for a wallet
  // payment (see walletClickSubmitRef above). Consumed (and cleared) by the tokenization
  // effects below so Stripe keeps Safari's user-activation window for the Apple Pay sheet.
  const pendingWalletSubmitRef = React.useRef<ReturnType<StripeElements["submit"]> | null>(null);
  // The Payment Element's change event reports which payment-method row the buyer selected
  // (`value.type` — "card", "apple_pay", "google_pay", ...). We remember it in a ref so that at
  // submit time tokenization knows whether a wallet is paying — wallet submissions must keep the
  // wallet sheet's own billing details instead of the checkout form's (see
  // card_payment_method_data.ts). A ref (not state) because it's only read inside the submit
  // effect and shouldn't cause re-renders. Defaults to "card": with wallets disabled the element
  // only ever shows the card form.
  const paymentElementTypeRef = React.useRef("card");
  // A tokenized wallet payment held back because the wallet's billing address changed checkout's
  // tax location (see the submit effect below). A ref, not state: it's produced inside the async
  // submit effect and consumed by the resolution effect — it never drives rendering itself (the
  // resolution effect re-runs on the surcharges/status changes that decide its fate).
  const heldWalletPaymentRef = React.useRef<HeldWalletPayment<PurchasePaymentMethod> | null>(null);
  const useStripePaymentElement = canUseStripePaymentElement(state);
  const useStripePaymentElementClientConfirm = canUseStripePaymentElementClientConfirm(state);
  const usesPaymentElement = useStripePaymentElement || useStripePaymentElementClientConfirm;
  const stripePaymentElementConfig =
    usesPaymentElement && state.checkoutPayment.integration !== "card_element"
      ? state.checkoutPayment.elements_options
      : null;

  // When the Payment Element renders Apple Pay, describe the cart's recurring agreement on the
  // sheet so Apple issues a device-independent merchant token (MPAN) — the exact same declaration
  // the Payment Request Button path builds below (getApplePayOption in useStripePaymentRequest),
  // via the same shared builder, so the two wallet surfaces can't drift. Applies to both element
  // modes the server-confirm lane uses: "payment" (subscriptions — regular recurring billing) and
  // "setup" (free trials / preorders — the builder emits the zero-amount trialBilling line there).
  // The client-confirm lane never gets a declaration: Checkout::PaymentMethodResolver only routes
  // one-time, non-recurring carts to it, so there is never a recurring agreement to declare.
  //
  // The builder computes the end date from "now", so it returns a fresh object every call; the
  // useMemo below keys on the declaration's content (end-date excluded, same reasoning as the
  // PRB's applePayRecurringDeclarationKey) so the options object keeps its identity between
  // renders and react-stripe-js only pushes an element.update() when the declaration really
  // changed — e.g. the cart flips between recurring-eligible and not, or the renewal price moves.
  const paymentElementApplePayOption =
    state.checkoutPayment.integration === "payment_element"
      ? getPaymentElementApplePayOption({
          products: state.products,
          managementURL: Routes.library_url(),
          requestApplePayMerchantTokens: state.checkoutPayment.request_apple_pay_merchant_tokens,
          paymentElementWallets: state.checkoutPayment.payment_element_wallets,
        })
      : undefined;
  const paymentElementApplePayOptionKey = JSON.stringify(paymentElementApplePayOption ?? null, (key, value: unknown) =>
    key === "recurringPaymentEndDate" ? undefined : value,
  );
  const memoizedPaymentElementApplePayOption = React.useMemo(
    () => paymentElementApplePayOption,
    // Intentionally keyed on the serialized content instead of the object, see the comment above.
    [paymentElementApplePayOptionKey],
  );
  const stripePaymentElementAmount = getStripePaymentElementAmount(state);
  // The element's mount currency — the FX quote's currency on the buyer-currency presentment
  // lane (stripePaymentElementAmount then carries the quote's local-currency total), canonical
  // USD otherwise, or null while an in-flight surcharge refresh makes it unknowable so the
  // input keeps its current mount instead of remounting and wiping entered card details.
  const stripePaymentElementMountCurrency = getStripePaymentElementMountCurrency(state);
  const handlePaymentElementReady = React.useCallback((controller: PaymentElementController | null) => {
    paymentElementRef.current = controller;
    // A fresh (re)mounted element always starts on the card form, but the ref outlives element
    // remounts (mode/currency switches, toggling a saved card). Without this reset, a buyer who
    // selected Apple Pay before a remount would still be recorded as paying by wallet even
    // though the remounted element is showing the card form — and the card submission would then
    // skip the checkout-form billing details it depends on. Reset to the safe default and let
    // the element's change event re-establish any wallet selection.
    paymentElementTypeRef.current = "card";
    setPaymentElementReady(controller !== null);
  }, []);

  React.useEffect(() => {
    if (!usesPaymentElement) handlePaymentElementReady(null);
  }, [handlePaymentElementReady, usesPaymentElement]);

  // Flat layout only: the buyer touched the Payment Element (focused a field or picked one of
  // its rows) while PayPal was checkout's selected payment method — that interaction IS the
  // "select the card/wallet lane" gesture in a single flat list, so switch back. Clicks inside
  // the element's iframe never reach the surrounding DOM, so the element's own focus/change
  // events are the only reliable signal.
  const reclaimCardLane = React.useCallback(() => {
    if (!flatPaymentMethodsList) return;
    if (state.paymentMethod !== "paypal" || isProcessing(state)) return;
    dispatch({ type: "set-value", paymentMethod: "card" });
  }, [flatPaymentMethodsList, state, dispatch]);

  // Flat layout only: the whole list is one payment-method selector, so only one row may be
  // expanded at a time. Picking PayPal collapses the element's expanded accordion row (Card /
  // Apple Pay / Google Pay), exactly like picking one of the element's own rows collapses its
  // siblings. Stripe's collapse() deselects the element's payment method without unmounting it,
  // so entered card details survive; interacting with the element again re-expands the clicked
  // row (and reclaimCardLane above switches checkout back to the card/wallet lane).
  // paymentElementReady is a dependency so a remounted element (currency/mode switch while
  // PayPal is selected) gets re-collapsed too — a fresh mount always renders expanded.
  const paymentMethodIsPayPal = state.paymentMethod === "paypal";
  React.useEffect(() => {
    if (!flatPaymentMethodsList || !paymentMethodIsPayPal || !paymentElementReady) return;
    paymentElementRef.current?.elements.getElement("payment")?.collapse();
  }, [flatPaymentMethodsList, paymentMethodIsPayPal, paymentElementReady]);

  // Expose the synchronous click-time wallet submit to the pay button (see walletClickSubmitRef
  // in the props above). Runs in the click handler itself: when a wallet row is selected on a
  // mounted element, kick off elements.submit() immediately so Stripe captures the click's
  // user-activation for opening the Apple Pay sheet later in the flow. Card submissions are
  // unaffected (tokenization keeps calling elements.submit() itself).
  React.useEffect(() => {
    if (!walletClickSubmitRef) return;
    walletClickSubmitRef.current = () => {
      // Every pay click starts from a clean slate. The ref is normally consumed (and cleared) by
      // the tokenization effect once status reaches "starting", but a wallet click that fails
      // checkout validation never gets there — without this reset, that stale wallet submit
      // would be reused by the NEXT attempt (even a card one), skipping the current element's
      // submit/validation and coupling the new attempt to the old wallet sheet.
      pendingWalletSubmitRef.current = null;
      const controller = paymentElementRef.current;
      if (!controller || !isWalletPaymentElementType(paymentElementTypeRef.current)) return;
      pendingWalletSubmitRef.current = controller.elements.submit();
      // Swallow here only to avoid an unhandled-rejection warning; tokenization awaits this same
      // promise and handles the error for real.
      pendingWalletSubmitRef.current.catch(() => {});
    };
    return () => {
      walletClickSubmitRef.current = null;
    };
  }, [walletClickSubmitRef]);

  React.useEffect(() => {
    onPaymentElementReadyChange?.(
      isCardReadyToPay({ useSavedCard, useStripePaymentElement: usesPaymentElement, paymentElementReady }),
    );
  }, [onPaymentElementReadyChange, useSavedCard, usesPaymentElement, paymentElementReady]);

  React.useEffect(() => {
    dispatch({
      type: "add-payment-method",
      paymentMethod: {
        type: "card",
        button: null,
      },
    });
  }, []);

  React.useEffect(() => {
    if (state.status.type !== "starting" || state.paymentMethod !== "card") return;
    (async () => {
      if (!useSavedCard && usesPaymentElement && !paymentElementReady) return;

      // Client-confirm checkout mints a ConfirmationToken; saved cards stay on server-confirm.
      if (useStripePaymentElementClientConfirm && !useSavedCard) {
        const controller = assertDefined(
          paymentElementRef.current,
          "`paymentElementRef.current` should be defined when confirming via the Payment Element",
        );
        const pendingSubmit = pendingWalletSubmitRef.current;
        pendingWalletSubmitRef.current = null;
        const tokenResult = await createPaymentElementConfirmationToken({
          stripe: controller.stripe,
          elements: controller.elements,
          email: state.email,
          fullName: state.fullName,
          zipCode: state.zipCode,
          country: state.country,
          state: state.state,
          city: state.city,
          address: state.address,
          walletSelected: isWalletPaymentElementType(paymentElementTypeRef.current),
          pendingSubmit,
        });
        if (tokenResult.status === "error") {
          setCardError(true);
          return dispatch({ type: "cancel" });
        }
        // A wallet paid through the Payment Element: adopt the wallet sheet's billing address as
        // checkout's tax location (same shared rules as the Payment Request Button path) before
        // the purchase params are posted. Skipped for shippable carts, where the shipping
        // address governs the tax location — matching the Payment Request Button behavior.
        const clientConfirmPaymentMethod: PurchasePaymentMethod = {
          type: "payment-element-client-confirm",
          confirmationTokenId: tokenResult.confirmationTokenId,
          cardCountry: tokenResult.cardCountry,
          walletType: tokenResult.wallet?.type ?? null,
          mountCurrency: stripePaymentElementConfig.currency,
        };
        if (tokenResult.wallet && !hasShipping(state)) {
          const taxLocationChanged = applyWalletBillingAddressToCheckout(
            tokenResult.wallet.billingAddress,
            state,
            dispatch,
          );
          // The wallet's billing address changed the tax location, invalidating the surcharges
          // quote — the server may now calculate a different total than the wallet sheet showed.
          // Hold the tokenized payment instead of submitting; the held-payment effect below
          // resumes it once surcharges reload, and only if the total the buyer approved still
          // matches. `state` here is the pre-change snapshot, so the recorded approved amount is
          // exactly what the wallet sheet displayed.
          if (taxLocationChanged) {
            heldWalletPaymentRef.current = {
              paymentMethod: clientConfirmPaymentMethod,
              approvedAmount: getStripePaymentElementAmount(state),
            };
            return;
          }
        }
        return dispatch({ type: "set-payment-method", paymentMethod: clientConfirmPaymentMethod });
      }

      if (!useSavedCard && !useStripePaymentElement && !cardElementRef.current) {
        setCardError(true);
        return dispatch({ type: "cancel" });
      }
      const serverConfirmPendingSubmit = pendingWalletSubmitRef.current;
      pendingWalletSubmitRef.current = null;
      const selectedPaymentMethod: SelectedPaymentMethod = useSavedCard
        ? { type: "saved" }
        : useStripePaymentElement
          ? {
              type: "payment-element",
              ...assertDefined(
                paymentElementRef.current,
                "`paymentElementRef.current` should be defined when the payment method is a Payment Element card",
              ),
              zipCode: state.zipCode,
              keepOnFile,
              email: state.email,
              fullName: state.fullName,
              country: state.country,
              state: state.state,
              city: state.city,
              address: state.address,
              walletSelected: isWalletPaymentElementType(paymentElementTypeRef.current),
              pendingSubmit: serverConfirmPendingSubmit,
            }
          : {
              type: "card",
              element: assertDefined(
                cardElementRef.current,
                "`cardElementRef.current` should be defined when the payment method is an unsaved card",
              ),
              zipCode: state.zipCode,
              keepOnFile,
              email: state.email,
            };

      const useReusablePaymentMethod = requiresReusablePaymentMethodForCardCollection(state, useStripePaymentElement);
      const paymentMethod = await (useReusablePaymentMethod
        ? getReusablePaymentMethodResult(selectedPaymentMethod, { products: state.products })
        : getPaymentMethodResult(selectedPaymentMethod));

      if (
        paymentMethod.type === "new" &&
        paymentMethod.cardParamsResult.cardParams.status === "error" &&
        paymentMethod.cardParamsResult.cardParams.stripe_error.type === "validation_error"
      ) {
        setCardError(true);
        return dispatch({ type: "cancel" });
      }
      // A wallet paid through the Payment Element (server-confirm lane): adopt the wallet
      // sheet's billing address as checkout's tax location (same shared rules as the Payment
      // Request Button path) before the purchase params are posted. Skipped for shippable
      // carts, where the shipping address governs the tax location.
      if (
        paymentMethod.type === "new" &&
        paymentMethod.cardParamsResult.type === "cc" &&
        paymentMethod.cardParamsResult.cardParams.wallet &&
        !hasShipping(state)
      ) {
        const taxLocationChanged = applyWalletBillingAddressToCheckout(
          paymentMethod.cardParamsResult.cardParams.wallet.billingAddress,
          state,
          dispatch,
        );
        // Same held-submission rule as the client-confirm wallet lane above: a tax-location
        // change invalidates the surcharges quote, so hold the tokenized payment until the
        // reload confirms the total still matches what the wallet sheet showed the buyer.
        if (taxLocationChanged) {
          heldWalletPaymentRef.current = {
            paymentMethod,
            approvedAmount: getStripePaymentElementAmount(state),
          };
          return;
        }
      }
      dispatch({ type: "set-payment-method", paymentMethod });
    })().catch(fail);
  }, [paymentElementReady, state.status.type, usesPaymentElement]);

  // Resolves a held wallet payment as checkout state settles (see the submit effect above for
  // why one exists). Re-runs whenever surcharges or the submission status move: while the
  // reload for the wallet's tax location is in flight, keep waiting; once it lands, submit the
  // held payment only if the recalculated total still matches the one the buyer approved on the
  // wallet sheet. On a mismatch the buyer must re-confirm — the Payment Element's amount has
  // already been updated to the recalculated total by the amount effect in
  // PaymentElementInput.tsx (it tracks getStripePaymentElementAmount), so the next wallet sheet
  // shows the new total. Charging a total the buyer never saw is never an option.
  React.useEffect(() => {
    const held = heldWalletPaymentRef.current;
    if (!held) return;
    const resolution = resolveHeldWalletPayment(state, held);
    if (resolution.type === "wait") return;
    heldWalletPaymentRef.current = null;
    if (resolution.type === "continue") {
      dispatch({ type: "set-payment-method", paymentMethod: resolution.paymentMethod });
    } else if (resolution.type === "re-confirm") {
      dispatch({ type: "cancel" });
      showAlert(
        "Your total changed after applying your payment method's billing address. Please review the updated total and try again.",
        "warning",
      );
    }
    // "abort": the submission was cancelled or failed elsewhere while holding — just drop it.
  }, [state.surcharges, state.status.type]);

  return (
    // In the flat wallets layout a click anywhere in the card area (the saved-card box, the
    // element's surrounding padding) re-selects the card/wallet lane from PayPal. Focus/change
    // events inside the element's iframe are handled separately (see reclaimCardLane); the
    // PayPal row itself stops propagation so selecting it doesn't immediately bounce back.
    <div className="flex flex-col gap-4" onClick={flatPaymentMethodsList ? reclaimCardLane : undefined}>
      {stripePaymentElementConfig && !useSavedCard ? (
        <div className="flex flex-col gap-4">
          {state.savedCreditCard && paymentElementReady ? (
            <button
              type="button"
              className="-mt-10 cursor-pointer self-end font-normal underline all-unset"
              disabled={isProcessing(state)}
              onClick={() => setUseSavedCard(true)}
            >
              Use saved card
            </button>
          ) : null}
          <PaymentElementInput
            amount={stripePaymentElementAmount}
            mountCurrency={stripePaymentElementMountCurrency}
            elementsOptions={stripePaymentElementConfig}
            walletsEnabled={state.checkoutPayment.payment_element_wallets}
            applePayOption={memoizedPaymentElementApplePayOption}
            disabled={isProcessing(state)}
            defaultEmail={state.email}
            defaultName={state.fullName}
            onReady={handlePaymentElementReady}
            invalid={cardError}
            onFocus={reclaimCardLane}
            onChange={(evt) => {
              paymentElementTypeRef.current = evt.value.type;
              if (evt.complete) setCardError(false);
              // A change means the buyer is interacting with the element — reclaim the
              // card/wallet lane from PayPal. Ignore the empty card-form event a freshly
              // (re)mounted element can emit without any interaction, so a background remount
              // (e.g. a currency switch) can't silently steal the buyer's PayPal selection.
              // Also ignore collapsed events: selecting PayPal programmatically collapses the
              // element (see the collapse effect above), and that collapse's own change event
              // must not bounce the selection straight back to card.
              if (!evt.collapsed && (!evt.empty || isWalletPaymentElementType(evt.value.type))) reclaimCardLane();
            }}
          />
        </div>
      ) : (
        <CreditCardInput
          savedCreditCard={state.savedCreditCard}
          disabled={isProcessing(state)}
          onReady={(element) => (cardElementRef.current = element)}
          invalid={cardError}
          useSavedCard={useSavedCard}
          setUseSavedCard={setUseSavedCard}
          onChange={(evt) => setCardError(!!evt.error)}
          enableLink
        />
      )}
      {paymentMethodsAppendix}
      {!useSavedCard && isLoggedIn && (!flatPaymentMethodsList || state.paymentMethod === "card") ? (
        <Label className="flex items-center gap-2">
          <Checkbox
            disabled={isProcessing(state)}
            checked={keepOnFile}
            onChange={(evt) => setKeepOnFile(evt.target.checked)}
          />
          Save card for future purchases
        </Label>
      ) : null}
    </div>
  );
};

const CreditCardPayButtonContent = ({
  disabled = false,
  isTestPurchase,
  onPayClick,
}: {
  disabled?: boolean;
  isTestPurchase?: boolean;
  // Called synchronously in the Pay click, before the submission pipeline starts — used to
  // capture the click's user-activation for wallet payments (see walletClickSubmitRef).
  onPayClick?: (() => void) | undefined;
}) => {
  const [state, dispatch] = useState();
  const payLabel = usePayLabel();

  return (
    <div className="flex flex-col gap-4">
      <Button
        color="primary"
        onClick={() => {
          onPayClick?.();
          dispatch({ type: "offer" });
        }}
        disabled={disabled || isSubmitDisabled(state)}
      >
        {payLabel}
      </Button>
      {isTestPurchase ? (
        <Alert variant="info">
          This will be a test purchase as you are the creator of at least one of the products. Your payment method will
          not be charged.
        </Alert>
      ) : null}
    </div>
  );
};

const BraintreePayPal = ({ token }: { token: string }) => {
  const [state, dispatch] = useState();
  const fail = useFail();
  const payLabel = usePayLabel();

  const [braintree, setBraintree] = React.useState<{ paypal: PayPal; dataCollector: DataCollector } | null>(null);
  useRunOnce(
    asyncVoid(async () => {
      const client = await BraintreeClient.create({ authorization: token });
      const paypal = await BraintreePaypal.create({ client });
      const dataCollector = await BraintreeDataCollector.create({ client, paypal: true });
      setBraintree({ paypal, dataCollector });
    }),
  );

  useOnChangeSync(() => {
    if (state.status.type !== "starting") return;
    // Use a layout effect because `braintree?.paypal.tokenize` needs to be called synchronously
    braintree?.paypal.tokenize({ flow: "vault", enableShippingAddress: hasShipping(state) }, (error, result) => {
      if (!result) {
        if (error?.code === "PAYPAL_POPUP_CLOSED") dispatch({ type: "cancel" });
        else fail();
        return;
      }
      (async () => {
        dispatch({
          type: "set-value",
          fullName: `${result.details.firstName} ${result.details.lastName}`,
          ...(state.email ? {} : { email: result.details.email }),
        });
        if (hasShipping(state)) {
          const address = result.details.shippingAddress;
          dispatch({
            type: "set-value",
            fullName: address.recipientName,
            address: `${address.line1} ${address.line2}`,
            city: address.city,
            country: address.countryCode,
            state: address.state || address.city,
            zipCode: address.postalCode,
          });
        }
        const selectedPaymentMethod: SelectedPaymentMethod = {
          type: "paypal-braintree",
          nonce: result.nonce,
          keepOnFile: true,
          deviceData: braintree.dataCollector.deviceData,
        };
        dispatch({
          type: "set-payment-method",
          paymentMethod: await (requiresReusablePaymentMethod(state)
            ? getReusablePaymentMethodResult(selectedPaymentMethod, { products: state.products })
            : getPaymentMethodResult(selectedPaymentMethod)),
        });
      })().catch(fail);
    });
  }, [state.status.type]);

  return (
    <Button color="paypal" onClick={() => dispatch({ type: "offer" })} disabled={isSubmitDisabled(state)}>
      <Paypal pack="brands" className="size-5" />
      {payLabel}
    </Button>
  );
};

const NativePayPal = ({ implementation }: { implementation: PayPalNamespace }) => {
  const [state, dispatch] = useState();
  const fail = useFail();
  const isDarkTheme = useIsDarkTheme();

  const ref = React.useRef<HTMLDivElement>(null);

  const [payPromise, setPayPromise] = React.useState<{ resolve: () => void; reject: (e: Error) => void } | null>(null);

  React.useEffect(() => {
    if (!payPromise) return;
    if (state.status.type === "input") payPromise.reject(new Error());
    else payPromise.resolve();
    setPayPromise(null);
  }, [state.status.type, payPromise]);

  const stateRef = useRefToLatest(state);

  const [paymentMethod, setPaymentMethod] = React.useState<null | PurchasePaymentMethod>(null);

  React.useEffect(() => {
    if (!paymentMethod || state.status.type !== "starting") return;
    dispatch({ type: "set-payment-method", paymentMethod });
  }, [paymentMethod, state.status.type]);

  useRunOnce(() => {
    if (!ref.current) return;
    void implementation
      .Buttons?.({
        style: { color: "black", label: "pay", tagline: false },
        createBillingAgreement: () => createBillingAgreementToken({ shipping: hasShipping(state) }),
        onApprove: async (data) => {
          assert(data.billingToken != null, "Billing token missing");
          const result = await createBillingAgreement(data.billingToken);
          dispatch({
            type: "set-value",
            country: result.payer.payer_info.billing_address.country_code,
            zipCode: result.payer.payer_info.billing_address.postal_code,
            fullName: `${result.payer.payer_info.first_name ?? ""} ${result.payer.payer_info.last_name ?? ""}`,
            ...(stateRef.current.email ? {} : { email: result.payer.payer_info.email }),
          });
          if (result.shipping_address) {
            const address = result.shipping_address;
            dispatch({
              type: "set-value",
              country: address.country_code,
              state: address.state || address.city,
              zipCode: address.postal_code,
              city: address.city,
              fullName: address.recipient_name,
              address: address.line1 + (address.line2 ?? ""),
            });
          }
          const selectedPaymentMethod: SelectedPaymentMethod = {
            type: "paypal-native",
            info: {
              kind: "billingAgreement",
              billingToken: data.billingToken,
              agreementId: result.id,
              email: result.payer.payer_info.email,
              country: result.payer.payer_info.billing_address.country_code,
            },
            keepOnFile: null,
          };

          setPaymentMethod(
            await (requiresReusablePaymentMethod(state)
              ? getReusablePaymentMethodResult(selectedPaymentMethod, { products: state.products })
              : getPaymentMethodResult(selectedPaymentMethod)),
          );
        },
        onError: fail,
        onCancel: () => dispatch({ type: "cancel" }),
        onClick: (_, actions) =>
          new Promise<void>((resolve, reject) => {
            setPayPromise({ resolve, reject });
            dispatch({ type: "offer" });
          }).then(actions.resolve, actions.reject),
      })
      .render(ref.current);
  });

  return (
    <>
      <div
        ref={ref}
        className={classNames(isProcessing(state) && "hidden")}
        style={isDarkTheme ? { filter: "invert(1) grayscale(1)" } : undefined}
      />
      {isProcessing(state) ? <LoadingSpinner /> : null}
    </>
  );
};

const usePayPalImplementation = () => {
  const [state] = useState();
  const [nativePaypal, setNativePaypal] = React.useState<PayPalNamespace | null>(null);
  useRunOnce(
    asyncVoid(async () => {
      if (!state.paypalClientId) return;
      setNativePaypal(await loadPaypal({ clientId: state.paypalClientId, vault: true }));
    }),
  );
  const braintreeToken = useBraintreeToken(true);
  const implementation = state.products.reduce<Product["supports_paypal"]>((impl, item) => {
    if (impl === "native" && item.supportsPaypal === "native" && nativePaypal) return "native";
    if (impl !== null && item.supportsPaypal !== null && braintreeToken.type === "available") return "braintree";
    return null;
  }, "native");

  return { implementation, nativePaypal, braintreeToken };
};

const PayPalContent = () => {
  const [state, dispatch] = useState();
  const { implementation, nativePaypal, braintreeToken } = usePayPalImplementation();

  React.useEffect(() => {
    if (!implementation) return;
    dispatch({
      type: "add-payment-method",
      paymentMethod: {
        type: "paypal",
        button: null,
      },
    });
  }, [implementation]);

  // Use a layout effect because the Braintree modal has to be opened synchronously
  useOnChangeSync(() => {
    if (state.paymentMethod !== "paypal") return;
    if (state.status.type === "validating") dispatch({ type: "start-payment" });
    if (state.status.type !== "input") return;
    const errors = state.status.errors;
    const error = errors.has("email")
      ? "Please provide a valid email address."
      : errors.has("fullName")
        ? "Please enter your full name."
        : hasShipping(state) && addressFields.some((field) => errors.has(field))
          ? "The shipping address you have entered is in an invalid format."
          : null;
    if (error) showAlert(error, "error");
  }, [state.status.type]);

  if (!implementation) return null;

  return (
    <div className="flex flex-col items-center gap-4">
      {nativePaypal && implementation === "native" ? (
        <NativePayPal implementation={nativePaypal} />
      ) : braintreeToken.type === "available" ? (
        <BraintreePayPal token={braintreeToken.token} />
      ) : null}
    </div>
  );
};

const useIsPayPalAvailable = () => {
  const { implementation } = usePayPalImplementation();
  return !!implementation;
};

const useStripePaymentRequest = (disabled: boolean) => {
  const [state, dispatch] = useState();
  const stripe = useStripe();
  const fail = useFail();

  const [shippingAddressChangeEvent, setShippingAddressChangeEvent] =
    React.useState<PaymentRequestShippingAddressEvent | null>(null);
  const [paymentMethodEvent, setPaymentMethodEvent] = React.useState<PaymentRequestPaymentMethodEvent | null>(null);
  const [paymentMethods, setPaymentMethods] = React.useState<CanMakePaymentResult | null>(null);

  // The wallet sheet's total mirrors the checkout table's "Payment today" row (the cart total
  // minus future installment payments) so the sheet always shows the same number the buyer just
  // read at checkout. The amount actually charged is decided server-side.
  const getTotalItem = () => ({ amount: getChargeTodayPrice(state) ?? 0, label: "Gumroad" });
  const stateRef = useRefToLatest(state);

  // When the cart contains a subscription, describe the recurring agreement on the Apple Pay
  // sheet. This makes Apple issue a merchant token (MPAN) — a token tied to the buyer's card and
  // Gumroad rather than to the physical device — so renewals keep working after the buyer wipes
  // or replaces their phone. Behind a per-seller flag while we verify token issuance in
  // production; without the flag the sheet stays a plain one-time request and Apple issues a
  // device token, exactly as before.
  //
  // Reads `state` directly (NOT stateRef): this is called during render from the useMemo below,
  // and stateRef only catches up in an effect AFTER render — inside the memo it still holds the
  // previous products, which would rebuild the PaymentRequest from exactly the stale declaration
  // the rebuild was meant to discard (e.g. switching an item from installments to pay-in-full
  // kept declaring the installment plan).
  const getApplePayOption = () => {
    if (!state.checkoutPayment.request_apple_pay_merchant_tokens) return null;
    return getApplePayRecurringPaymentRequest(state.products, Routes.library_url());
  };

  // Stripe's PaymentRequest#update can change an existing recurring declaration but not remove
  // one, so whenever cart edits change what the recurring agreement should say — the cart flips
  // between recurring-eligible and not, one membership is swapped for another, or the renewal
  // price changes — rebuild the PaymentRequest from scratch instead of letting a stale recurring
  // agreement linger on the Apple Pay sheet. The key serializes the declaration's content so any
  // change to it triggers a rebuild; the end date is excluded because it's computed from "now"
  // (so it would differ on every call) and every change that moves it also changes another field
  // in the declaration (the billing agreement text spells out the number of payments).
  const applePayRecurringDeclarationKey = JSON.stringify(getApplePayOption(), (key, value: unknown) =>
    key === "recurringPaymentEndDate" ? undefined : value,
  );

  const paymentRequest = React.useMemo(() => {
    if (!stripe || disabled) return null;
    const applePayRecurringPaymentRequest = getApplePayOption();
    const paymentRequest = stripe.paymentRequest({
      country: "US",
      currency: "usd",
      total: getTotalItem(),
      requestPayerEmail: true,
      requestShipping: state.products.some((item) => item.requireShipping),
      requestPayerName: true,
      ...(applePayRecurringPaymentRequest
        ? { applePay: { recurringPaymentRequest: applePayRecurringPaymentRequest } }
        : {}),
    });
    const getAddress = (address: PaymentRequestShippingAddress) => ({
      state: (address.region || address.city) ?? "",
      address: address.addressLine?.join(", ") ?? "",
      city: address.city ?? "",
      fullName: address.recipient ?? "",
      zipCode: address.postalCode ?? "",
      country: address.country ?? "",
    });
    paymentRequest.canMakePayment().then(setPaymentMethods, () => setPaymentMethods(null));
    paymentRequest.on("shippingaddresschange", (e) => {
      dispatch({ type: "set-value", ...getAddress(e.shippingAddress) });
      setShippingAddressChangeEvent(e);
    });
    paymentRequest.on("cancel", () => dispatch({ type: "cancel" }));
    paymentRequest.on("paymentmethod", (e) =>
      (async () => {
        const state = stateRef.current;
        if (hasShipping(state) && e.shippingAddress) dispatch({ type: "set-value", ...getAddress(e.shippingAddress) });
        if (!hasShipping(state) && e.paymentMethod.billing_details.address?.country) {
          // Tax-critical: adopt the wallet sheet's billing address as checkout's tax location.
          // The rules (and the reasoning behind them) live in applyWalletBillingAddressToCheckout,
          // which the Payment Element wallet path shares so the two surfaces can't drift.
          applyWalletBillingAddressToCheckout(e.paymentMethod.billing_details.address, state, dispatch);
        }
        dispatch({ type: "set-value", fullName: e.payerName, ...(state.email ? {} : { email: e.payerEmail }) });
        setPaymentMethodEvent(e);
        const selectedPaymentMethod = preparePaymentRequestPaymentMethodData(e);
        dispatch({
          type: "set-payment-method",
          paymentMethod: requiresReusablePaymentMethod(state)
            ? await getReusablePaymentRequestPaymentMethodResult(selectedPaymentMethod, { products: state.products })
            : getPaymentRequestPaymentMethodResult(selectedPaymentMethod),
        });
      })().catch(fail),
    );
    return paymentRequest;
  }, [stripe, disabled, applePayRecurringDeclarationKey]);

  // Use a layout effect because `paymentRequest.show` needs to be called synchronously
  useOnChangeSync(() => {
    if (state.paymentMethod !== "stripePaymentRequest") return;
    if (state.status.type === "validating") dispatch({ type: "start-payment" });
    else if (state.status.type === "starting") paymentRequest?.show();
    else if (paymentMethodEvent) {
      const errors = getErrors(state);
      if (state.status.type === "captcha") paymentMethodEvent.complete("success");
      else if (state.status.type === "input") {
        if (errors.has("email")) paymentMethodEvent.complete("invalid_payer_email");
        else if (errors.has("fullName")) paymentMethodEvent.complete("invalid_payer_name");
        else if (addressFields.some((field) => errors.has(field)))
          paymentMethodEvent.complete("invalid_shipping_address");
        else paymentMethodEvent.complete("fail");
      } else return;
      setPaymentMethodEvent(null);
    }
  }, [state.status.type]);

  React.useEffect(() => {
    if (!paymentRequest) return;
    if (shippingAddressChangeEvent) {
      shippingAddressChangeEvent.updateWith(
        state.surcharges.type === "loaded"
          ? {
              status: "success",
              shippingOptions: [
                {
                  id: "standard",
                  label: "Standard Shipping",
                  detail: "",
                  amount: state.surcharges.result.shipping_rate_cents,
                },
              ],
              total: getTotalItem(),
            }
          : { status: "invalid_shipping_address" },
      );
      setShippingAddressChangeEvent(null);
    } else if (
      // This guard prevents us from updating the total while the Apple
      // Pay payment sheet is open, which throws an error. We need this
      // because the surcharges are reloaded after we update the ZIP code
      // to the Apple Pay billing ZIP code during payment.
      (state.status.type === "input" || state.status.type === "validating") &&
      state.surcharges.type === "loaded"
    ) {
      const applePayRecurringPaymentRequest = getApplePayOption();
      paymentRequest.update({
        total: getTotalItem(),
        // Keep the renewal amount on the Apple Pay sheet in sync when discounts, taxes, or cart
        // edits change prices after the payment request was created.
        ...(applePayRecurringPaymentRequest
          ? { applePay: { recurringPaymentRequest: applePayRecurringPaymentRequest } }
          : {}),
      });
    }
  }, [state.surcharges, shippingAddressChangeEvent]);

  const canPay = paymentMethods && (paymentMethods.googlePay || paymentMethods.applePay);
  const isGooglePay = paymentMethods?.googlePay ?? false;
  const isApplePay = paymentMethods?.applePay ?? false;

  React.useEffect(() => {
    if (!canPay) return;
    dispatch({
      type: "add-payment-method",
      paymentMethod: {
        type: "stripePaymentRequest",
        button: null,
      },
    });
  }, [canPay]);

  return { canPay: !!canPay, isGooglePay, isApplePay };
};

const StripePaymentRequestContent = () => {
  const [state, dispatch] = useState();
  const payLabel = usePayLabel();

  return (
    <div className="flex flex-col gap-4">
      <Button color="primary" onClick={() => dispatch({ type: "offer" })} disabled={isSubmitDisabled(state)}>
        {payLabel}
      </Button>
    </div>
  );
};

const StripePaymentRequestRadioOption = ({ canPay, isGooglePay }: { canPay: boolean; isGooglePay: boolean }) => {
  if (!canPay) return null;

  const label = isGooglePay ? "Google Pay" : "Apple Pay";
  const icon = isGooglePay ? <Google pack="brands" className="size-5" /> : <Apple pack="brands" className="size-5" />;

  return (
    <div className="border-t border-border">
      <PaymentMethodRadioRow paymentMethod="stripePaymentRequest" label={label} icon={icon} />
    </div>
  );
};

const StripePaymentRequestPayButton = ({ canPay }: { canPay: boolean }) => {
  const [state] = useState();

  if (!canPay || state.paymentMethod !== "stripePaymentRequest") return null;

  return <StripePaymentRequestContent />;
};

// PayPal rendered as one more row of the flat payment-methods list used when the Payment
// Element shows wallets (payment_element_wallets — see PaymentMethodsSection). The element's
// accordion already lists Card / Apple Pay / Google Pay as bordered rounded rows (the
// ".AccordionItem" appearance rule in PaymentElementInput.tsx), so this row copies that look —
// same border, radius, and padding — and sits directly below the element, making the whole
// list read as one selector: Card / wallets / PayPal. The element's rows never change border
// color when selected (selection shows as the row expanding), so this row keeps the plain
// border too — selecting PayPal collapses the element's rows (see the collapse effect in
// CreditCardContent) and surfaces the PayPal button, which is the selection cue.
const FlatPayPalRow = () => {
  const [state, dispatch] = useState();
  const selected = state.paymentMethod === "paypal";
  const disabled = !selected && isProcessing(state);

  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      disabled={disabled}
      className={classNames(
        // all-unset resets box-sizing to content-box, which would make w-full + padding + border
        // overflow the parent — box-border restores the border-box sizing every other row uses.
        "box-border flex w-full cursor-pointer items-center gap-3 rounded border border-border p-4 text-left all-unset",
        disabled && "cursor-not-allowed opacity-50",
      )}
      onClick={(e) => {
        // The surrounding CreditCardContent container treats clicks as "re-select the
        // card/wallet lane" in this layout; picking PayPal must not bounce straight back.
        e.stopPropagation();
        if (state.paymentMethod !== "paypal") dispatch({ type: "set-value", paymentMethod: "paypal" });
      }}
    >
      <Paypal pack="brands" className="size-5" />
      <span className="font-medium">PayPal</span>
    </button>
  );
};

const PaymentMethodsSection = ({
  isPayPalAvailable,
  isTestPurchase,
}: {
  isPayPalAvailable: boolean;
  isTestPurchase: boolean;
}) => {
  const [state] = useState();
  // The Payment Request Button is disabled when the Payment Element renders wallets itself
  // (payment_element_wallets — see antiwork/gumroad#5768): showing both would give the buyer two
  // Apple Pay buttons. Carts on the CardElement fallback lane never mount a Payment Element, and
  // the presenter always sends payment_element_wallets: false for them, so they keep the button.
  const { canPay, isGooglePay } = useStripePaymentRequest(
    state.checkoutPayment.disable_wallets || state.checkoutPayment.payment_element_wallets,
  );
  const [paymentElementReady, setPaymentElementReady] = React.useState(false);
  const handlePaymentElementReadyChange = React.useCallback((ready: boolean) => setPaymentElementReady(ready), []);
  // Bridges the card Pay button's click to CreditCardContent's click-time wallet submit — see
  // walletClickSubmitRef on CreditCardContent for why wallet payments must submit the element
  // synchronously in the click.
  const walletClickSubmitRef = React.useRef<(() => void) | null>(null);
  const handleCardPayClick = React.useCallback(() => walletClickSubmitRef.current?.(), []);

  const hasMultiplePaymentMethods = isPayPalAvailable || canPay;
  const usesPaymentElement = canUseStripePaymentElement(state) || canUseStripePaymentElementClientConfirm(state);
  const cardPayDisabled = usesPaymentElement && !paymentElementReady;

  // Flat payment-methods list (payment_element_wallets): the element's accordion IS the
  // payment-method selector — Card and the wallets render as its rows — so the outer "Card"
  // radio row is dropped entirely and PayPal is appended as one more matching row below the
  // element (see FlatPayPalRow). No nesting, no duplicate "Card". The element stays mounted
  // while PayPal is selected (unmounting would wipe entered card details); interacting with it
  // re-selects the card/wallet lane.
  if (usesPaymentElement && state.checkoutPayment.payment_element_wallets) {
    return (
      <>
        <CreditCardContent
          onPaymentElementReadyChange={handlePaymentElementReadyChange}
          walletClickSubmitRef={walletClickSubmitRef}
          flatPaymentMethodsList
          paymentMethodsAppendix={isPayPalAvailable ? <FlatPayPalRow /> : null}
        />
        {state.paymentMethod === "paypal" ? <PayPalContent /> : null}
        {state.paymentMethod === "card" ? (
          <CreditCardPayButtonContent
            disabled={cardPayDisabled}
            isTestPurchase={isTestPurchase}
            onPayClick={handleCardPayClick}
          />
        ) : null}
      </>
    );
  }

  if (usesPaymentElement && !hasMultiplePaymentMethods) {
    return (
      <>
        <CreditCardContent
          onPaymentElementReadyChange={handlePaymentElementReadyChange}
          walletClickSubmitRef={walletClickSubmitRef}
        />
        {state.paymentMethod === "card" ? (
          <CreditCardPayButtonContent
            disabled={cardPayDisabled}
            isTestPurchase={isTestPurchase}
            onPayClick={handleCardPayClick}
          />
        ) : null}
      </>
    );
  }

  return (
    <>
      <div className="overflow-hidden rounded border border-border">
        {hasMultiplePaymentMethods ? (
          <PaymentMethodRadioRow paymentMethod="card" label="Card" icon={<CreditCard className="size-5" />} />
        ) : (
          <div className="flex items-center gap-3 bg-body p-4">
            <CreditCard className="size-5" />
            <span className="font-medium">Card</span>
          </div>
        )}
        {state.paymentMethod === "card" ? (
          <div className={hasMultiplePaymentMethods ? "bg-body p-4 pt-0" : "bg-body px-4 pb-4"}>
            <CreditCardContent
              onPaymentElementReadyChange={handlePaymentElementReadyChange}
              walletClickSubmitRef={walletClickSubmitRef}
            />
          </div>
        ) : null}
        {isPayPalAvailable ? (
          <div className="border-t border-border">
            <PaymentMethodRadioRow
              paymentMethod="paypal"
              label="PayPal"
              icon={<Paypal pack="brands" className="size-5" />}
            />
          </div>
        ) : null}
        <StripePaymentRequestRadioOption canPay={canPay} isGooglePay={isGooglePay} />
      </div>
      {state.paymentMethod === "paypal" ? <PayPalContent /> : null}
      {state.paymentMethod === "card" ? (
        <CreditCardPayButtonContent
          disabled={cardPayDisabled}
          isTestPurchase={isTestPurchase}
          onPayClick={handleCardPayClick}
        />
      ) : null}
      <StripePaymentRequestPayButton canPay={canPay} />
    </>
  );
};

export const PaymentForm = ({
  className,
  notice,
  showCustomFields = true,
  borderless = false,
}: React.HTMLAttributes<HTMLDivElement> & {
  notice?: string | null;
  showCustomFields?: boolean;
  borderless?: boolean;
}) => {
  const [state, dispatch] = useState();
  const loggedInUser = useLoggedInUser();
  const isTestPurchase = loggedInUser && state.products.find((product) => product.testPurchase);
  const isFreePurchase = isTestPurchase || !requiresPayment(state);

  const paymentFormRef = React.useRef<HTMLDivElement | null>(null);
  const recaptcha = useRecaptcha({
    siteKey: state.recaptchaKey,
    scoreBased: state.recaptchaScoreBased,
    action: "checkout",
  });

  React.useEffect(() => {
    if (paymentFormRef.current && state.status.type === "input") {
      // Stripe nests the input inside aria-invalid, hence the second query selector.
      paymentFormRef.current
        .querySelector<HTMLInputElement>("input[aria-invalid=true], [aria-invalid=true] input")
        ?.focus();
    }

    if (state.status.type === "starting" && isFreePurchase) {
      dispatch({ type: "set-payment-method", paymentMethod: { type: "not-applicable" } });
    }

    if (state.status.type === "captcha") {
      if ((process.env.NODE_ENV === "development" || process.env.NODE_ENV === "test") && state.recaptchaKey === null) {
        dispatch({ type: "set-recaptcha-response" });
      } else {
        recaptcha
          .execute()
          .then((recaptchaResponse) => dispatch({ type: "set-recaptcha-response", recaptchaResponse }))
          .catch((e: unknown) => {
            // The security check being unloadable (ad blocker / privacy extension / restricted
            // network) is fixable by the buyer, but only if we say so — a silent reset here
            // strands them with no way to complete checkout (see gumroad-private#927).
            if (e instanceof RecaptchaUnavailableError) {
              showAlert(RECAPTCHA_UNAVAILABLE_MESSAGE, "error");
            } else {
              assert(e instanceof RecaptchaCancelledError);
            }
            dispatch({ type: "cancel" });
          });
      }
    }
  }, [state.status.type]);

  const isPayPalAvailable = useIsPayPalAvailable();

  return (
    <div ref={paymentFormRef} className={`flex flex-col gap-6 ${className}`} aria-label="Payment form">
      {showCustomFields ? <CustomFields className="p-4 sm:p-5" /> : null}
      <CustomerDetails className="flex flex-wrap items-center justify-between gap-4 p-4 sm:p-5" />
      {!isFreePurchase ? (
        <Card borderless={borderless}>
          <CardContent className="sm:p-5">
            <div className="flex grow flex-col gap-4">
              <h4 className="text-base sm:text-lg">Pay with</h4>
              <StripeElementsProvider>
                <PaymentMethodsSection isPayPalAvailable={isPayPalAvailable} isTestPurchase={!!isTestPurchase} />
              </StripeElementsProvider>
            </div>
          </CardContent>
          {notice ? (
            <CardContent className="sm:p-5">
              <Alert variant="info" className="grow">
                {notice}
              </Alert>
            </CardContent>
          ) : null}
        </Card>
      ) : (
        <PayButton
          className="flex flex-wrap items-center justify-between gap-4 p-4 sm:p-5"
          isTestPurchase={!!isTestPurchase}
        />
      )}
      {recaptcha.container}
    </div>
  );
};
