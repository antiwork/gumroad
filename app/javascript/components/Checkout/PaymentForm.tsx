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
import { VerificationResult, verifyShippingAddress } from "$app/data/shipping";
import { assert, assertDefined } from "$app/utils/assert";
import { GST_ONLY_FALLBACK_PROVINCE, provinceForCanadianPostalCode } from "$app/utils/canadianPostalCodes";
import { classNames } from "$app/utils/classNames";
import { checkEmailForTypos as checkEmailForTyposUtil } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { persistAcknowledgedEmail } from "$app/components/Checkout/acknowledgedEmails";
import { getApplePayRecurringPaymentRequest } from "$app/components/Checkout/applePayRecurringPaymentRequest";
import { CreditCardInput, StripeElementsProvider } from "$app/components/Checkout/CreditCardInput";
import { CustomFields } from "$app/components/Checkout/CustomFields";
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
import { PaymentElementController, PaymentElementInput } from "$app/components/Checkout/PaymentElementInput";
import { Dropdown } from "$app/components/Dropdown";
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
  const fail = useFail();

  const [addressVerification, setAddressVerification] = React.useState<VerificationResult | null>(null);
  const verifyAddress = () =>
    setAddressVerification({
      type: "done",
      verifiedAddress: { state: state.state, city: state.city, street_address: state.address, zip_code: state.zipCode },
    });
  const errors = getErrors(state);

  React.useEffect(() => {
    if (state.status.type === "input") setAddressVerification(null);
    if (state.status.type !== "validating") return;
    if (hasShipping(state)) {
      verifyShippingAddress({
        country: state.country,
        state: state.state,
        city: state.city,
        street_address: state.address,
        zip_code: state.zipCode,
      }).then((result) => {
        if (state.status.type === "validating") setAddressVerification(result);
      }, fail);
    } else dispatch({ type: "start-payment" });
  }, [state.status.type]);

  React.useEffect(() => {
    if (addressVerification?.type === "done") {
      const { verifiedAddress } = addressVerification;
      dispatch({
        type: "set-value",
        address: verifiedAddress.street_address,
        city: verifiedAddress.city,
        state: verifiedAddress.state,
        zipCode: verifiedAddress.zip_code,
      });
      dispatch({ type: "start-payment" });
    }
  }, [addressVerification]);

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
          {addressVerification && addressVerification.type !== "done" ? (
            <Dropdown className="flex flex-col gap-4">
              {addressVerification.type === "verification-required" ? (
                <>
                  <div>
                    <strong>You entered this address:</strong>
                    <br />
                    {addressVerification.formattedOriginalAddress}
                  </div>
                  <div>
                    <strong>We recommend using this format:</strong>
                    <br />
                    {addressVerification.formattedSuggestedAddress}
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button onClick={verifyAddress}>No, continue</Button>
                    <Button
                      color="primary"
                      onClick={() =>
                        setAddressVerification({ type: "done", verifiedAddress: addressVerification.suggestedAddress })
                      }
                    >
                      Yes, update
                    </Button>
                  </div>
                </>
              ) : (
                <>
                  {addressVerification.type === "invalid"
                    ? addressVerification.message
                    : "We are unable to verify your shipping address. Is your address correct?"}
                  <Button onClick={() => dispatch({ type: "cancel" })}>No</Button>
                  <Button onClick={verifyAddress}>Yes, it is</Button>
                </>
              )}
            </Dropdown>
          ) : null}
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
}: {
  onPaymentElementReadyChange?: ((ready: boolean) => void) | undefined;
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
  const useStripePaymentElement = canUseStripePaymentElement(state);
  const useStripePaymentElementClientConfirm = canUseStripePaymentElementClientConfirm(state);
  const usesPaymentElement = useStripePaymentElement || useStripePaymentElementClientConfirm;
  const stripePaymentElementConfig =
    usesPaymentElement && state.checkoutPayment.integration !== "card_element"
      ? state.checkoutPayment.elements_options
      : null;
  const stripePaymentElementAmount = getStripePaymentElementAmount(state);
  // The element's mount currency — the FX quote's currency on the buyer-currency presentment
  // lane (stripePaymentElementAmount then carries the quote's local-currency total), canonical
  // USD otherwise, or null while an in-flight surcharge refresh makes it unknowable so the
  // input keeps its current mount instead of remounting and wiping entered card details.
  const stripePaymentElementMountCurrency = getStripePaymentElementMountCurrency(state);
  const handlePaymentElementReady = React.useCallback((controller: PaymentElementController | null) => {
    paymentElementRef.current = controller;
    setPaymentElementReady(controller !== null);
  }, []);

  React.useEffect(() => {
    if (!usesPaymentElement) handlePaymentElementReady(null);
  }, [handlePaymentElementReady, usesPaymentElement]);

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
        });
        if (tokenResult.status === "error") {
          setCardError(true);
          return dispatch({ type: "cancel" });
        }
        return dispatch({
          type: "set-payment-method",
          paymentMethod: {
            type: "payment-element-client-confirm",
            confirmationTokenId: tokenResult.confirmationTokenId,
            cardCountry: tokenResult.cardCountry,
          },
        });
      }

      if (!useSavedCard && !useStripePaymentElement && !cardElementRef.current) {
        setCardError(true);
        return dispatch({ type: "cancel" });
      }
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
      dispatch({ type: "set-payment-method", paymentMethod });
    })().catch(fail);
  }, [paymentElementReady, state.status.type, usesPaymentElement]);

  return (
    <div className="flex flex-col gap-4">
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
            disabled={isProcessing(state)}
            defaultEmail={state.email}
            defaultName={state.fullName}
            onReady={handlePaymentElementReady}
            invalid={cardError}
            onChange={(evt) => {
              if (evt.complete) setCardError(false);
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
      {!useSavedCard && isLoggedIn ? (
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
}: {
  disabled?: boolean;
  isTestPurchase?: boolean;
}) => {
  const [state, dispatch] = useState();
  const payLabel = usePayLabel();

  return (
    <div className="flex flex-col gap-4">
      <Button
        color="primary"
        onClick={() => dispatch({ type: "offer" })}
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
          // Honor the wallet's billing country for ALL countries, not just US. Checkout state
          // defaults `country` to "US" when the account has no country and geo-detection fails,
          // so without this a non-US Apple Pay / Google Pay buyer submits taxCountryElection "US"
          // with an empty ZIP and the server's US-only ZIP validation rejects the purchase with
          // "You entered a ZIP Code that doesn't exist within your country" — an error the buyer
          // can't fix because the wallet flow never shows a ZIP field. The billing state/province
          // is copied too because Canadian tax lookup requires it alongside the country. When the
          // wallet omits a state we clear the field rather than keep the old value, so a stale
          // province from a previous selection can't pair with the new country and produce a
          // wrong tax calculation. For Canada specifically, some wallets share only the postal
          // code without the province — since every Canadian postal code's first letter maps to
          // exactly one province or territory, we derive the province from the postal code so
          // Canadian tax can still be calculated (the wallet flow has no province field the
          // buyer could fill in manually). If the wallet gives neither a state nor a usable
          // Canadian postal code, we still must not submit a blank province: Canadian tax is only
          // calculated when a province is present, so "CA" with an empty province would silently
          // collect no tax, and the wallet flow gives the buyer no province field to correct it.
          // In that case we keep the existing checkout state when the wallet's billing country
          // matches the country checkout already had (it came from the buyer's saved address or
          // geo-detection for that same country, so it isn't stale). As a true last resort for
          // Canada — the wallet gave no province, no usable postal code, and checkout had no
          // prior Canadian province — we elect Alberta. That choice is deliberate, not an
          // arbitrary list default: Alberta charges only the 5% federal GST, which applies to
          // buyers in every province and territory. Electing it when the real province is
          // unknowable means we always collect the federal portion the buyer owes regardless of
          // where they live, and we never charge them another province's higher HST/PST or remit
          // provincial tax to a jurisdiction they may not be in.
          const billingAddress = e.paymentMethod.billing_details.address;
          const billingState =
            billingAddress.state ||
            (billingAddress.country === "CA" ? provinceForCanadianPostalCode(billingAddress.postal_code) : null) ||
            (billingAddress.country === state.country ? state.state : null) ||
            (billingAddress.country === "CA" ? GST_ONLY_FALLBACK_PROVINCE : null);
          dispatch({ type: "set-value", country: billingAddress.country });
          dispatch({ type: "set-value", zipCode: billingAddress.postal_code || undefined });
          dispatch({ type: "set-value", state: billingState ?? "" });
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

const PaymentMethodsSection = ({
  isPayPalAvailable,
  isTestPurchase,
}: {
  isPayPalAvailable: boolean;
  isTestPurchase: boolean;
}) => {
  const [state] = useState();
  const { canPay, isGooglePay } = useStripePaymentRequest(state.checkoutPayment.disable_wallets);
  const [paymentElementReady, setPaymentElementReady] = React.useState(false);
  const handlePaymentElementReadyChange = React.useCallback((ready: boolean) => setPaymentElementReady(ready), []);

  const hasMultiplePaymentMethods = isPayPalAvailable || canPay;
  const usesPaymentElement = canUseStripePaymentElement(state) || canUseStripePaymentElementClientConfirm(state);
  const cardPayDisabled = usesPaymentElement && !paymentElementReady;

  if (usesPaymentElement && !hasMultiplePaymentMethods) {
    return (
      <>
        <CreditCardContent onPaymentElementReadyChange={handlePaymentElementReadyChange} />
        {state.paymentMethod === "card" ? (
          <CreditCardPayButtonContent disabled={cardPayDisabled} isTestPurchase={isTestPurchase} />
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
            <CreditCardContent onPaymentElementReadyChange={handlePaymentElementReadyChange} />
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
        <CreditCardPayButtonContent disabled={cardPayDisabled} isTestPurchase={isTestPurchase} />
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
