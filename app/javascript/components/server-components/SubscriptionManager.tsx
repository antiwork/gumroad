import { parseISO } from "date-fns";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { confirmLineItem } from "$app/data/purchase";
import { cancelSubscriptionByUser, updateSubscription } from "$app/data/subscription";
import { SavedCreditCard } from "$app/parsers/card";
import { Discount } from "$app/parsers/checkout";
import { CustomFieldDescriptor, ProductNativeType } from "$app/parsers/product";
import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
  getMinPriceCents,
} from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { recurrenceLabels, RecurrenceId } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Creator } from "$app/components/Checkout/cartState";
import {
  createReducer,
  StateContext,
  Product as PaymentProduct,
  getTotalPrice,
} from "$app/components/Checkout/payment";
import { PaymentForm } from "$app/components/Checkout/PaymentForm";
import { useFeatureFlags } from "$app/components/FeatureFlags";
import {
  Option,
  PriceSelection,
  ConfigurationSelector,
  Product as ConfigurationSelectorProduct,
  applySelection,
} from "$app/components/Product/ConfigurationSelector";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

import { useOnChangeSync } from "../useOnChange";

type Props = {
  product: {
    permalink: string;
    name: string;
    native_type: ProductNativeType;
    require_shipping: boolean;
    custom_fields: CustomFieldDescriptor[];
    supports_paypal: "native" | "braintree" | null;
    creator: Creator;
    currency_code: CurrencyCode;
    options: Option[];
    price_cents: number;
    is_tiered_membership: boolean;
    is_legacy_subscription: boolean;
    is_multiseat_license: boolean;
    recurrences: { id: string; recurrence: RecurrenceId; price_cents: number }[];
    pwyw: { suggested_price_cents: number | null } | null;
    installment_plan: { number_of_installments: number } | null;
    exchange_rate: number;
    shippable_country_codes: string[];
  };
  subscription: {
    id: string;
    recurrence: RecurrenceId;
    option_id: string | null;
    price: number;
    quantity: number;
    alive: boolean;
    pending_cancellation: boolean;
    prorated_discount_price_cents: number;
    discount: Discount | null;
    end_time_of_subscription: string;
    successful_purchases_count: number;
    is_in_free_trial: boolean;
    is_test: boolean;
    is_overdue_for_charge: boolean;
    is_gift: boolean;
    is_installment_plan: boolean;
  };
  contact_info: {
    email: string;
    full_name: string;
    street: string;
    city: string;
    state: string;
    zip: string;
    country: string;
  };
  countries: Record<string, string>;
  us_states: string[];
  ca_provinces: string[];
  used_card: SavedCreditCard | null;
  recaptcha_key: string;
  paypal_client_id: string;
};

const SubscriptionManager = ({
  product,
  subscription,
  recaptcha_key,
  paypal_client_id,
  contact_info,
  countries,
  us_states,
  ca_provinces,
  used_card,
}: Props) => {
  const url = new URL(useOriginalLocation());

  const subscriptionEntity = subscription.is_installment_plan ? "installment plan" : "membership";
  const restartable = !subscription.alive || subscription.pending_cancellation;
  const [cancelled, setCancelled] = React.useState(restartable);
  const initialSelection = {
    recurrence: subscription.recurrence,
    rent: false,
    optionId: subscription.option_id,
    quantity: subscription.quantity,
    price: { value: subscription.price / subscription.quantity, error: false },
    callStartTime: null,
    payInInstallments: subscription.is_installment_plan,
  };
  const [selection, setSelection] = React.useState<PriceSelection>(() => initialSelection);
  const currentOption = product.options.find(({ id }) => id === subscription.option_id);
  const hasPriceChanged =
    Math.round(subscription.price / subscription.quantity) !==
    currentOption?.recurrence_price_values?.[subscription.recurrence]?.price_cents;
  const configurationSelectorProduct: ConfigurationSelectorProduct = {
    ...product,
    options: product.options.map((option) =>
      option.id === subscription.option_id
        ? {
            ...option,
            status: hasPriceChanged
              ? `Your current plan is ${formatPriceCentsWithCurrencySymbol(
                  product.currency_code,
                  Math.round(subscription.price / subscription.quantity),
                  { symbolFormat: "long" },
                )} ${recurrenceLabels[subscription.recurrence]}, based on previous pricing. This price will remain the same when updating your payment method.`
              : undefined,
          }
        : option,
    ),
    recurrences: { default: subscription.recurrence, enabled: product.recurrences },
    is_tiered_membership: product.is_tiered_membership,
    is_legacy_subscription: product.is_legacy_subscription,
    rental: null,
    is_quantity_enabled: false,
    quantity_remaining: null,
    is_multiseat_license: product.is_multiseat_license,
    ppp_details: null,
  };

  const { isPWYW, discountedPriceCents } = applySelection(
    configurationSelectorProduct,
    subscription.discount,
    selection,
  );
  const isQuantityChanged = selection.quantity !== subscription.quantity;
  const isRecurrenceChanged = selection.recurrence !== subscription.recurrence;
  const noChangesToNonPriceOptions =
    selection.optionId === subscription.option_id && !isRecurrenceChanged && !isQuantityChanged;

  let warning = null;
  if (selection.optionId === subscription.option_id && hasPriceChanged) {
    const price = `${formatPriceCentsWithCurrencySymbol(product.currency_code, discountedPriceCents, { symbolFormat: "long" })} ${recurrenceLabels[selection.recurrence ?? subscription.recurrence]}`;
    if (isQuantityChanged && isRecurrenceChanged) {
      warning = `Changing the number of seats and adjusting the billing frequency will update your subscription to the current price of ${price} per seat.`;
    } else if (isQuantityChanged) {
      warning = `Changing the number of seats will update your subscription to the current price of ${price} per seat.`;
    } else if (isRecurrenceChanged) {
      warning = `Changing the billing frequency will update your subscription to the current price of ${price} per seat.`;
    }
  }

  const price =
    (isPWYW || noChangesToNonPriceOptions ? (selection.price.value ?? discountedPriceCents) : discountedPriceCents) *
    selection.quantity;
  const requirePayment = price > 0;
  const noChangesToCurrentPlan = noChangesToNonPriceOptions && (!isPWYW || price === subscription.price);
  let amountDueToday =
    (subscription.alive || subscription.pending_cancellation) &&
    !subscription.is_overdue_for_charge &&
    (price < subscription.price || subscription.is_in_free_trial || noChangesToCurrentPlan)
      ? 0
      : Math.max(price - subscription.prorated_discount_price_cents, 0);
  if (amountDueToday > 0) amountDueToday = Math.max(amountDueToday, getMinPriceCents(product.currency_code));
  const paymentProduct: PaymentProduct = {
    permalink: product.permalink,
    name: product.name,
    creator: product.creator,
    quantity: 1,
    price: Math.round(amountDueToday / product.exchange_rate),
    payInInstallments: subscription.is_installment_plan,
    requireShipping: product.require_shipping,
    customFields: product.custom_fields,
    bundleProductCustomFields: [],
    supportsPaypal: product.supports_paypal,
    testPurchase: subscription.is_test,
    requirePayment,
    subscription_id: subscription.id,
    recommended_by: null,
    shippableCountryCodes: product.shippable_country_codes,
    hasTippingEnabled: false,
    hasFreeTrial: false,
    nativeType: product.native_type,
    canGift: false,
  };
  const payLabel = cancelled ? `Restart ${subscriptionEntity}` : `Update ${subscriptionEntity}`;
  const { require_email_typo_acknowledgment } = useFeatureFlags();
  const reducer = createReducer({
    country: contact_info.country,
    email: contact_info.email,
    fullName: contact_info.full_name,
    address: contact_info,
    countries,
    usStates: us_states,
    caProvinces: ca_provinces,
    tipOptions: [],
    defaultTipOption: 0,
    savedCreditCard: used_card,
    state: contact_info.state,
    products: [paymentProduct],
    payLabel,
    recaptchaKey: recaptcha_key,
    paypalClientId: paypal_client_id,
    gift: null,
    requireEmailTypoAcknowledgment: require_email_typo_acknowledgment,
  });
  const [state, dispatchAction] = reducer;
  React.useEffect(
    () => dispatchAction({ type: "update-products", products: [paymentProduct] }),
    [amountDueToday, requirePayment],
  );
  React.useEffect(() => dispatchAction({ type: "set-value", warning }), [warning]);
  React.useEffect(() => dispatchAction({ type: "set-value", payLabel }), [payLabel]);
  const totalPrice = getTotalPrice(state) ?? 0;
  const vat = state.surcharges.type === "loaded" ? state.surcharges.result.tax_cents : 0;

  async function pay() {
    if (state.status.type !== "finished") return;
    const result = await updateSubscription({
      cardParams:
        state.status.paymentMethod.type === "not-applicable" || state.status.paymentMethod.type === "saved"
          ? null
          : state.status.paymentMethod.cardParamsResult.cardParams,
      recaptchaResponse: state.status.recaptchaResponse ?? null,
      declined: url.searchParams.get("declined") === "true",
      subscription_id: subscription.id,
      variants: selection.optionId ? [selection.optionId] : [],
      price_id: product.recurrences.find((recurrence) => recurrence.recurrence === selection.recurrence)?.id,
      perceived_price_cents: price,
      perceived_upgrade_price_cents: amountDueToday,
      quantity: selection.quantity,
      price_range: isPWYW ? (selection.price.value ?? 0) * selection.quantity : undefined,
      contact_info: {
        country: state.country,
        email: state.email,
        state: state.state,
        full_name: state.fullName,
        street_address: state.address,
        zip_code: state.zipCode,
        city: state.city,
      },
    });
    if (result.type === "done") {
      showAlert(result.message, "success");
      setCancelled(false);
      setCancellationStatus("initial");
      if (result.next != null) {
        window.location.href = result.next;
      }
    } else if (result.type === "requires_card_action") {
      await confirmLineItem({
        success: true,
        requires_card_action: true,
        client_secret: result.client_secret,
        purchase: result.purchase,
      }).then((itemResult) => {
        if (itemResult.success) {
          showAlert(`Your ${subscriptionEntity} has been updated.`, "success");
          setCancelled(false);
          setCancellationStatus("initial");
        }
      });
    } else {
      showAlert(result.message, "error", { html: true });
    }
    dispatchAction({ type: "cancel" });
  }
  React.useEffect(() => void pay(), [state.status]);

  // show (the Stripe Payment Request method that triggers the Apple Pay
  // modal) can't be called in asynchronous code, so we have to use a
  // synchronous layout effect.
  useOnChangeSync(() => {
    if (state.status.type === "offering") dispatchAction({ type: "validate" });
  }, [state.status.type]);

  const [cancellationStatus, setCancellationStatus] = React.useState<"initial" | "processing" | "done">("initial");
  const handleCancel = asyncVoid(async () => {
    if (cancellationStatus === "processing" || cancellationStatus === "done") return;
    setCancellationStatus("processing");
    try {
      await cancelSubscriptionByUser(subscription.id);
      setCancellationStatus("done");
      setCancelled(true);
    } catch (e) {
      assertResponseError(e);
      setCancellationStatus("initial");
      showAlert("Sorry, something went wrong.", "error");
    }
  });

  const hasSavedCard = state.savedCreditCard != null;
  const isPendingFirstGifteePayment = subscription.is_gift && subscription.successful_purchases_count === 1;
  const formattedSubscriptionEndDate = parseISO(subscription.end_time_of_subscription).toLocaleDateString(undefined, {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
  const isFutureEndDate = parseISO(subscription.end_time_of_subscription) > new Date();
  const paymentNotice =
    isPendingFirstGifteePayment && isFutureEndDate && subscription.alive
      ? `Your first charge will be on ${formattedSubscriptionEndDate}.`
      : null;

  return (
    <div className="stack input-group mx-auto my-8 max-w-2xl">
      <header>
        {`Manage ${subscriptionEntity}`}
        <h2>{product.name}</h2>
      </header>

      {!hasSavedCard && subscription.is_gift ? (
        <div>
          <div role="alert" className="warning">
            <div>
              Your {subscriptionEntity} is paid up until {formattedSubscriptionEndDate}. Add your own payment method
              below to ensure that your {subscriptionEntity} renews.
            </div>
          </div>
        </div>
      ) : null}

      {!subscription.is_installment_plan ? (
        <div style={{ display: "grid", gap: "1rem", gridTemplateColumns: "1fr" }}>
          <ConfigurationSelector
            product={configurationSelectorProduct}
            selection={selection}
            setSelection={setSelection}
            initialSelection={initialSelection}
            discount={subscription.discount}
          />
        </div>
      ) : null}

      <StateContext.Provider value={reducer}>
        <div>
          <PaymentForm className="borderless" notice={paymentNotice} />
          {totalPrice > 0 ? (
            <div>
              <div style={{ textAlign: "center" }}>
                {vat > 0
                  ? `You'll be charged ${formatUSDCentsWithExpandedCurrencySymbol(totalPrice)} today, including ${formatUSDCentsWithExpandedCurrencySymbol(vat)} for VAT in ${state.countries[state.country] ?? ""}.`
                  : `You'll be charged ${formatUSDCentsWithExpandedCurrencySymbol(totalPrice)} today.`}
              </div>
            </div>
          ) : null}
        </div>
      </StateContext.Provider>

      {!restartable && !subscription.is_installment_plan ? (
        <div>
          <Button
            color="danger"
            outline
            onClick={handleCancel}
            disabled={cancellationStatus === "processing" || cancellationStatus === "done"}
          >
            {cancellationStatus === "done" ? "Cancelled" : `Cancel ${subscriptionEntity}`}
          </Button>
        </div>
      ) : null}
    </div>
  );
};

export default register({ component: SubscriptionManager, propParser: createCast() });
