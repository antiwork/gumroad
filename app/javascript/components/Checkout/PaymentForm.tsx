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
import cx from "classnames";
import * as React from "react";

import { useBraintreeToken } from "$app/data/braintree_client_token_data";
import { preparePaymentRequestPaymentMethodData } from "$app/data/card_payment_method_data";
import {
  getReusablePaymentMethodResult,
  getPaymentRequestPaymentMethodResult,
  getReusablePaymentRequestPaymentMethodResult,
  getPaymentMethodResult,
  SelectedPaymentMethod,
} from "$app/data/payment_method_result";
import { createBillingAgreement, createBillingAgreementToken } from "$app/data/paypal";
import { PurchasePaymentMethod } from "$app/data/purchase";
import { VerificationResult, verifyShippingAddress } from "$app/data/shipping";
import { assert, assertDefined } from "$app/utils/assert";
import { formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";
import { checkEmailForTypos as checkEmailForTyposUtil } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { CreditCardInput, StripeElementsProvider } from "$app/components/Checkout/CreditCardInput";
import { CustomFields } from "$app/components/Checkout/CustomFields";
import { GiftForm } from "$app/components/Checkout/GiftForm";
import {
  addressFields,
  getErrors,
  getTotalPrice,
  hasShipping,
  PaymentMethodType,
  useState,
  requiresPayment,
  isProcessing,
  usePayLabel,
  requiresReusablePaymentMethod,
  isSubmitDisabled,
  isTippingEnabled,
  getTotalPriceFromProducts,
} from "$app/components/Checkout/payment";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PriceInput } from "$app/components/PriceInput";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { Tabs } from "$app/components/ui/Tabs";
import { useIsDarkTheme } from "$app/components/useIsDarkTheme";
import { useOnChangeSync } from "$app/components/useOnChange";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";
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
    <fieldset>
      <legend>
        <label htmlFor={`${uid}country`}>Country</label>
      </legend>
      <select
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
      </select>
    </fieldset>
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
    <fieldset className={cx({ danger: errors.has("state") })}>
      <legend>
        <label htmlFor={`${uid}state`}>{stateLabel}</label>
      </legend>
      {(state.country === "US" || state.country === "CA") && states !== null ? (
        <select
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
        </select>
      ) : (
        <input
          id={`${uid}state`}
          type="text"
          aria-invalid={errors.has("state")}
          placeholder={stateLabel}
          disabled={isProcessing(state)}
          value={state.state}
          onChange={(e) => dispatch({ type: "set-value", state: e.target.value })}
        />
      )}
    </fieldset>
  );
};

const ZipCodeInput = () => {
  const [state, dispatch] = useState();
  const uid = React.useId();
  const errors = getErrors(state);
  const label = state.country === "US" || state.country === "PH" ? "ZIP code" : "Postal";

  return (
    <fieldset className={cx({ danger: errors.has("zipCode") })}>
      <legend>
        <label htmlFor={`${uid}zipCode`}>{label}</label>
      </legend>
      <input
        id={`${uid}zipCode`}
        type="text"
        aria-invalid={errors.has("zipCode")}
        placeholder={label}
        value={state.zipCode}
        onChange={(e) => dispatch({ type: "set-value", zipCode: e.target.value })}
        disabled={isProcessing(state)}
      />
    </fieldset>
  );
};

const EmailAddress = () => {
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
    dispatch({ type: "acknowledge-email-typo", email: state.email });
  };

  const acceptEmailTypoSuggestion = () => {
    if (!state.emailTypoSuggestion) return;
    dispatch({ type: "set-value", email: state.emailTypoSuggestion });
    dispatch({ type: "acknowledge-email-typo", email: state.emailTypoSuggestion });
  };

  return (
    <div>
      <div className="paragraphs">
        <fieldset className={cx({ danger: errors.has("email") })}>
          <legend>
            <label htmlFor={`${uid}email`}>
              <h4>Email address</h4>
            </label>
          </legend>
          <div className={cx("popover", { expanded: !!state.emailTypoSuggestion })} style={{ width: "100%" }}>
            <input
              id={`${uid}email`}
              type="email"
              aria-invalid={errors.has("email")}
              value={state.email}
              onChange={(evt) => dispatch({ type: "set-value", email: evt.target.value.toLowerCase() })}
              placeholder="Your email address"
              disabled={(loggedInUser && loggedInUser.email !== null) || isProcessing(state)}
              onBlur={checkForEmailTypos}
            />

            {state.emailTypoSuggestion ? (
              <div className="dropdown override grid gap-2">
                <div>Did you mean {state.emailTypoSuggestion}?</div>

                <div className="button-group">
                  <Button onClick={rejectEmailTypoSuggestion}>No</Button>
                  <Button onClick={acceptEmailTypoSuggestion}>Yes</Button>
                </div>
              </div>
            ) : null}
          </div>
        </fieldset>
      </div>
    </div>
  );
};

const SharedInputs = () => {
  const uid = React.useId();
  const [state, dispatch] = useState();
  const errors = getErrors(state);

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

  return (
    <>
      {showCountryInput || showVatIdInput ? (
        <div>
          <div className="paragraphs">
            <h4>Contact information</h4>
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
              <fieldset className={cx({ danger: errors.has("vatId") })}>
                <legend>
                  <label htmlFor={`${uid}vatId`}>{vatLabel}</label>
                </legend>
                <input
                  id={`${uid}vatId`}
                  type="text"
                  placeholder={vatLabel}
                  value={state.vatId}
                  onChange={(e) => dispatch({ type: "set-value", vatId: e.target.value })}
                  disabled={isProcessing(state)}
                />
              </fieldset>
            ) : null}
          </div>
        </div>
      ) : null}
      <CustomFields />
    </>
  );
};

const PaymentMethodRadio = ({
  paymentMethod,
  children,
}: {
  paymentMethod: PaymentMethodType;
  children: React.ReactNode;
}) => {
  const [state, dispatch] = useState();
  const selected = state.paymentMethod === paymentMethod;
  return (
    <Button
      role="tab"
      aria-selected={selected}
      onClick={() => {
        if (paymentMethod !== state.paymentMethod) dispatch({ type: "set-value", paymentMethod });
      }}
      disabled={!selected && isProcessing(state)}
    >
      {children}
    </Button>
  );
};

const useFail = () => {
  const [_, dispatch] = useState();
  return () => {
    showAlert("Sorry, something went wrong. You were not charged.", "error");
    dispatch({ type: "cancel" });
  };
};

const CustomerDetails = () => {
  const isLoggedIn = !!useLoggedInUser();
  const [state, dispatch] = useState();
  const uid = React.useId();
  const payLabel = usePayLabel();
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
      <SharedInputs />
      {hasShipping(state) ? (
        <div>
          <div className="paragraphs">
            <h4 style={{ display: "flex", justifyContent: "space-between" }}>
              Shipping information
              {isLoggedIn ? (
                <label>
                  <input
                    type="checkbox"
                    title="Save shipping address to account"
                    checked={state.saveAddress}
                    onChange={(e) => dispatch({ type: "set-value", saveAddress: e.target.checked })}
                    disabled={isProcessing(state)}
                  />
                  Keep on file
                </label>
              ) : null}
            </h4>
            <fieldset className={cx({ danger: errors.has("fullName") })}>
              <legend>
                <label htmlFor={`${uid}fullName`}>Full name</label>
              </legend>
              <input
                id={`${uid}fullName`}
                type="text"
                aria-invalid={errors.has("fullName")}
                placeholder="Full name"
                disabled={isProcessing(state)}
                value={state.fullName}
                onChange={(e) => dispatch({ type: "set-value", fullName: e.target.value })}
              />
            </fieldset>
            <fieldset className={cx({ danger: errors.has("address") })}>
              <legend>
                <label htmlFor={`${uid}address`}>Street address</label>
              </legend>
              <input
                id={`${uid}address`}
                type="text"
                aria-invalid={errors.has("address")}
                placeholder="Street address"
                disabled={isProcessing(state)}
                value={state.address}
                onChange={(e) => dispatch({ type: "set-value", address: e.target.value })}
              />
            </fieldset>
            <div style={{ display: "grid", gridAutoFlow: "column", gridAutoColumns: "1fr", gap: "var(--spacer-2)" }}>
              <fieldset className={cx({ danger: errors.has("city") })}>
                <legend>
                  <label htmlFor={`${uid}city`}>City</label>
                </legend>
                <input
                  id={`${uid}city`}
                  type="text"
                  aria-invalid={errors.has("city")}
                  placeholder="City"
                  disabled={isProcessing(state)}
                  value={state.city}
                  onChange={(e) => dispatch({ type: "set-value", city: e.target.value })}
                />
              </fieldset>
              <StateInput />
              <ZipCodeInput />
            </div>
            <CountryInput />
          </div>
          {addressVerification && addressVerification.type !== "done" ? (
            <div className="dropdown paragraphs">
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
                  <div className="button-group">
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
            </div>
          ) : null}
        </div>
      ) : null}
      {state.warning ? (
        <div>
          <div role="status" className="warning">
            {state.warning}
          </div>
        </div>
      ) : null}
      {isTippingEnabled(state) ? <TipSelector /> : null}
      {state.products.length === 1 && state.products[0]?.canGift && !state.products[0]?.payInInstallments ? (
        <GiftForm isMembership={state.products[0]?.nativeType === "membership"} />
      ) : null}
      <div>
        <Button color="primary" onClick={() => dispatch({ type: "offer" })} disabled={isSubmitDisabled(state)}>
          {payLabel}
        </Button>
      </div>
    </>
  );
};

const CreditCard = () => {
  const [state, dispatch] = useState();
  const fail = useFail();
  const isLoggedIn = !!useLoggedInUser();

  const uid = React.useId();
  const cardElementRef = React.useRef<StripeCardElement | null>(null);
  const [useSavedCard, setUseSavedCard] = React.useState(!!state.savedCreditCard);
  const [nameOnCard, setNameOnCard] = React.useState("");
  const [keepOnFile, setKeepOnFile] = React.useState(isLoggedIn);

  const [cardError, setCardError] = React.useState(false);

  React.useEffect(
    () =>
      dispatch({
        type: "add-payment-method",
        paymentMethod: {
          type: "card",
          button: (
            <PaymentMethodRadio paymentMethod="card">
              <Icon name="outline-credit-card" />
              <h4>Card</h4>
            </PaymentMethodRadio>
          ),
        },
      }),
    [],
  );

  React.useEffect(() => {
    if (state.status.type !== "starting" || state.paymentMethod !== "card") return;
    (async () => {
      if (!useSavedCard && !cardElementRef.current) {
        setCardError(true);
        return dispatch({ type: "cancel" });
      }
      const selectedPaymentMethod: SelectedPaymentMethod = useSavedCard
        ? { type: "saved" }
        : {
            type: "card",
            element: assertDefined(
              cardElementRef.current,
              "`cardElementRef.current` should be defined when the payment method is an unsaved card",
            ),
            zipCode: state.zipCode,
            keepOnFile,
            fullName: nameOnCard,
            email: state.email,
          };

      const paymentMethod = await (requiresReusablePaymentMethod(state)
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
  }, [state.status.type]);

  if (state.paymentMethod !== "card") return null;

  return (
    <>
      <div style={{ borderTop: "none", paddingTop: "0" }}>
        <div className="paragraphs">
          {!useSavedCard ? (
            <fieldset>
              <legend>
                <label htmlFor={`${uid}nameOnCard`}>Name on card</label>
                {isLoggedIn ? (
                  <label>
                    <input
                      type="checkbox"
                      disabled={isProcessing(state)}
                      checked={keepOnFile}
                      onChange={(evt) => setKeepOnFile(evt.target.checked)}
                    />
                    Save card
                  </label>
                ) : null}
              </legend>
              <input
                type="text"
                placeholder="John Doe"
                id={`${uid}nameOnCard`}
                value={nameOnCard}
                disabled={isProcessing(state)}
                onChange={(evt) => setNameOnCard(evt.target.value)}
              />
            </fieldset>
          ) : null}
          <CreditCardInput
            savedCreditCard={state.savedCreditCard}
            disabled={isProcessing(state)}
            onReady={(element) => (cardElementRef.current = element)}
            invalid={cardError}
            useSavedCard={useSavedCard}
            setUseSavedCard={setUseSavedCard}
            onChange={(evt) => setCardError(!!evt.error)}
          />
        </div>
      </div>
      <CustomerDetails />
    </>
  );
};

const TipSelector = () => {
  const [state, dispatch] = useState();
  const errors = getErrors(state);
  const showPercentageOptions = getTotalPriceFromProducts(state) > 0;

  React.useEffect(() => {
    if (!showPercentageOptions && state.tip.type === "percentage")
      dispatch({ type: "set-value", tip: { type: "fixed", amount: null } });
  }, [showPercentageOptions]);

  const defaultOther = state.surcharges.type === "loaded" ? state.surcharges.result.subtotal * 0.3 : 5;

  return (
    <div>
      <div className="paragraphs">
        <h4>Add a tip</h4>
        {showPercentageOptions ? (
          <div
            role="radiogroup"
            className="radio-buttons"
            style={{ gridTemplateColumns: "repeat(auto-fit, minmax(min(5rem, 100%), 1fr))" }}
          >
            {state.tipOptions.map((tip) => (
              <Button
                key={tip}
                role="radio"
                aria-checked={state.tip.type === "percentage" && tip === state.tip.percentage}
                onClick={() => {
                  dispatch({
                    type: "set-value",
                    tip: {
                      type: "percentage",
                      percentage: tip,
                    },
                  });
                }}
                disabled={isProcessing(state)}
                style={{ justifyContent: "center" }}
              >
                {tip}%
              </Button>
            ))}
            <Button
              role="radio"
              aria-checked={state.tip.type === "fixed"}
              onClick={() => {
                dispatch({
                  type: "set-value",
                  tip: {
                    type: "fixed",
                    amount: state.tip.type === "fixed" ? state.tip.amount : defaultOther,
                  },
                });
              }}
              disabled={isProcessing(state)}
              style={{ justifyContent: "center" }}
            >
              Other
            </Button>
          </div>
        ) : null}
        {state.tip.type === "fixed" ? (
          <fieldset className={cx({ danger: errors.has("tip") })}>
            <PriceInput
              hasError={errors.has("tip")}
              ariaLabel="Tip"
              currencyCode="usd"
              cents={state.tip.amount}
              onChange={(newAmount) => {
                dispatch({ type: "set-value", tip: { type: "fixed", amount: newAmount } });
              }}
              placeholder={formatPriceCentsWithoutCurrencySymbol("usd", defaultOther)}
              disabled={isProcessing(state)}
            />
          </fieldset>
        ) : null}
      </div>
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
    <Button className="button-paypal" onClick={() => dispatch({ type: "offer" })} disabled={isSubmitDisabled(state)}>
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
        hidden={isProcessing(state)}
        style={isDarkTheme ? { filter: "invert(1) grayscale(1)" } : undefined}
      />
      {isProcessing(state) ? <Progress width="1em" /> : null}
    </>
  );
};

const PayPal = () => {
  const [state, dispatch] = useState();

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
  React.useEffect(() => {
    if (!implementation) return;
    dispatch({
      type: "add-payment-method",
      paymentMethod: {
        type: "paypal",
        button: (
          <PaymentMethodRadio paymentMethod="paypal">
            <span className="brand-icon brand-icon-paypal" />
            <h4>PayPal</h4>
          </PaymentMethodRadio>
        ),
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

  if (state.paymentMethod !== "paypal" || !implementation) return null;
  return (
    <>
      <SharedInputs />
      {isTippingEnabled(state) ? <TipSelector /> : null}
      <div>
        {nativePaypal && implementation === "native" ? (
          <NativePayPal implementation={nativePaypal} />
        ) : braintreeToken.type === "available" ? (
          <BraintreePayPal token={braintreeToken.token} />
        ) : null}
      </div>
    </>
  );
};

const StripePaymentRequest = () => {
  const [state, dispatch] = useState();
  const stripe = useStripe();
  const fail = useFail();
  const payLabel = usePayLabel();

  const [shippingAddressChangeEvent, setShippingAddressChangeEvent] =
    React.useState<PaymentRequestShippingAddressEvent | null>(null);
  const [paymentMethodEvent, setPaymentMethodEvent] = React.useState<PaymentRequestPaymentMethodEvent | null>(null);
  const [paymentMethods, setPaymentMethods] = React.useState<CanMakePaymentResult | null>(null);

  const getTotalItem = () => ({ amount: getTotalPrice(state) ?? 0, label: "Gumroad" });
  const stateRef = useRefToLatest(state);

  const paymentRequest = React.useMemo(() => {
    if (!stripe) return null;
    const paymentRequest = stripe.paymentRequest({
      country: "US",
      currency: "usd",
      total: getTotalItem(),
      requestPayerEmail: true,
      requestShipping: state.products.some((item) => item.requireShipping),
      requestPayerName: true,
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
        if (!hasShipping(state) && e.paymentMethod.billing_details.address?.country === "US") {
          dispatch({ type: "set-value", country: "US" });
          dispatch({ type: "set-value", zipCode: e.paymentMethod.billing_details.address.postal_code || undefined });
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
  }, [stripe]);
  useOnChangeSync(() => {
    // use a layout effect because `paymentRequest.show` needs to be called synchronously
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
    )
      paymentRequest.update({ total: getTotalItem() });
  }, [state.surcharges, shippingAddressChangeEvent]);
  const canPay = paymentMethods && (paymentMethods.googlePay || paymentMethods.applePay);
  React.useEffect(() => {
    if (!canPay) return;
    dispatch({
      type: "add-payment-method",
      paymentMethod: {
        type: "stripePaymentRequest",
        button: (
          <PaymentMethodRadio paymentMethod="stripePaymentRequest">
            <span
              className={cx("brand-icon", {
                "brand-icon-google": paymentMethods.googlePay,
                "brand-icon-apple": paymentMethods.applePay,
              })}
            />
            <h4>{paymentMethods.googlePay ? "Google Pay" : "Apple Pay"}</h4>
          </PaymentMethodRadio>
        ),
      },
    });
  }, [canPay]);
  if (!canPay || state.paymentMethod !== "stripePaymentRequest") return null;

  return (
    <>
      <SharedInputs />
      {isTippingEnabled(state) ? <TipSelector /> : null}
      <div>
        <Button color="primary" onClick={() => dispatch({ type: "offer" })} disabled={isSubmitDisabled(state)}>
          {payLabel}
        </Button>
      </div>
    </>
  );
};

const FreePurchase = () => {
  const [state, dispatch] = useState();
  React.useEffect(() => {
    if (state.status.type === "starting")
      dispatch({ type: "set-payment-method", paymentMethod: { type: "not-applicable" } });
  }, [state.status.type]);
  return <CustomerDetails />;
};

export const PaymentForm = ({
  className,
  notice,
}: React.HTMLAttributes<HTMLDivElement> & { notice?: string | null }) => {
  const [state, dispatch] = useState();
  const loggedInUser = useLoggedInUser();
  const isTestPurchase = loggedInUser && state.products.find((product) => product.testPurchase);

  const paymentFormRef = React.useRef<HTMLDivElement | null>(null);
  const recaptcha = useRecaptcha({ siteKey: state.recaptchaKey });

  React.useEffect(() => {
    if (paymentFormRef.current && state.status.type === "input") {
      // Stripe nests the input inside aria-invalid, hence the second query selector.
      paymentFormRef.current
        .querySelector<HTMLInputElement>("input[aria-invalid=true], [aria-invalid=true] input")
        ?.focus();
    }

    if (state.status.type === "captcha") {
      if ((process.env.NODE_ENV === "development" || process.env.NODE_ENV === "test") && state.recaptchaKey === null) {
        dispatch({ type: "set-recaptcha-response" });
      } else {
        recaptcha
          .execute()
          .then((recaptchaResponse) => dispatch({ type: "set-recaptcha-response", recaptchaResponse }))
          .catch((e: unknown) => {
            assert(e instanceof RecaptchaCancelledError);
            dispatch({ type: "cancel" });
          });
      }
    }
  }, [state.status.type]);

  return (
    <div ref={paymentFormRef} className={cx("stack", className)} aria-label="Payment form">
      {isTestPurchase ? (
        <div>
          <div role="alert" className="info">
            This will be a test purchase as you are the creator of at least one of the products. Your payment method
            will not be charged.
          </div>
        </div>
      ) : null}
      {isTestPurchase || !requiresPayment(state) ? (
        <>
          <EmailAddress />
          <FreePurchase />
        </>
      ) : (
        <>
          <EmailAddress />
          <div>
            <div className="paragraphs">
              <h4>Pay with</h4>
              {state.availablePaymentMethods.length > 1 ? (
                <Tabs>
                  {state.availablePaymentMethods.map((method) => (
                    <React.Fragment key={method.type}>{method.button}</React.Fragment>
                  ))}
                </Tabs>
              ) : null}
            </div>
          </div>
          {notice ? (
            <div>
              <div role="alert" className="info">
                {notice}
              </div>
            </div>
          ) : null}
          <CreditCard />
          <PayPal />
          <StripeElementsProvider>
            <StripePaymentRequest />
          </StripeElementsProvider>
        </>
      )}
      {recaptcha.container}
    </div>
  );
};
