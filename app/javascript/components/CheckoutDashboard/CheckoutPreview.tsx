import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { Checkout } from "$app/components/Checkout";
import { CartItem } from "$app/components/Checkout/cartState";
import { StateContext as PaymentStateContext, createReducer } from "$app/components/Checkout/payment";
import { Preview } from "$app/components/Preview";
import { PreviewChrome, PreviewSidebar } from "$app/components/PreviewSidebar";

export const CheckoutPreview = ({
  children,
  cartItem,
  recommendedProduct,
}: {
  children?: React.ReactNode;
  cartItem: CartItem;
  recommendedProduct?: CardProduct | undefined;
}) => {
  const paymentState = React.useMemo<ReturnType<typeof createReducer>>(
    () => [
      {
        country: "United States",
        email: "",
        vatId: "",
        fullName: "",
        address: "",
        city: "",
        state: "",
        zipCode: "",
        saveAddress: false,
        gift: { type: "normal", email: "", note: "" },
        customFieldValues: {},
        // Loaded (with no surcharges) rather than pending: the payment element defers mounting
        // until it has a loaded total, and the preview should show the real payment fields, not
        // the loading placeholder.
        surcharges: {
          type: "loaded",
          result: {
            vat_id_valid: false,
            has_vat_id_input: false,
            shipping_rate_cents: 0,
            tax_cents: 0,
            tax_included_cents: 0,
            subtotal: cartItem.price,
            buyer_currency_quote: null,
          },
        },
        status: { type: "input", errors: new Set() },
        paymentMethod: "card",
        usStates: ["AA"],
        caProvinces: ["AA"],
        countries: { US: "United States" },
        tipOptions: [0, 15, 20, 25],
        savedCreditCard: null,
        paymentElementType: "card",
        willSaveCard: false,
        usingSavedCard: false,
        // The real checkout's canonical element config, so the preview renders the same payment
        // surface buyers see. The preview's surcharges never load, so the element itself stays
        // in its pre-mount state and no Stripe call is made.
        checkoutPayment: {
          integration: "payment_element",
          fallback_reason: null,
          disable_wallets: false,
          request_apple_pay_merchant_tokens: false,
          payment_element_wallets: false,
          flat_payment_methods: false,
          elements_options: {
            stripe_elements_mode: "payment",
            currency: "usd",
            buyer_currency_presentment: false,
            payment_method_types: ["card"],
            payment_method_creation: "manual",
            stripe_link_enabled: true,
          },
        },
        availablePaymentMethods: [],
        tip: { type: "percentage", percentage: 0 },
        emailTypoSuggestion: null,
        acknowledgedEmails: new Set<string>(),
        requireEmailTypoAcknowledgment: false,
        products: [
          {
            permalink: cartItem.product.permalink,
            name: cartItem.product.name,
            creator: cartItem.product.creator,
            requireShipping: cartItem.product.require_shipping,
            supportsPaypal: null,
            customFields: cartItem.product.custom_fields,
            bundleProductCustomFields: [],
            testPurchase: false,
            requirePayment: !!cartItem.product.free_trial,
            quantity: 1,
            price: cartItem.price,
            payInInstallments: cartItem.pay_in_installments,
            recommended_by: null,
            shippableCountryCodes: [],
            hasTippingEnabled: cartItem.product.has_tipping_enabled,
            hasFreeTrial: false,
            isPreorder: false,
            nativeType: "digital",
            recurrence: null,
            canGift: cartItem.product.can_gift,
          },
        ],
        paypalClientId: "",
        recaptchaKey: "",
        recaptchaScoreBased: false,
        recaptchaChallengeKey: null,
        checkoutPaymentStale: false,
        resumeSubmitAfterCheckoutPayment: false,
        validationFailedCount: 0,
      },
      () => undefined,
    ],
    [cartItem],
  );

  return (
    <PreviewSidebar>
      {/* This is a synthetic sample cart, so there is no public URL that shows this exact
          preview. Showing /checkout here would point to the seller's persisted cart instead. */}
      <PreviewChrome title="Checkout preview">
        <Preview scaleFactor={0.4}>
          <PaymentStateContext.Provider value={paymentState}>
            <Checkout
              discoverUrl=""
              cart={{
                items: [cartItem],
                discountCodes: [],
              }}
              updateCart={() => {}}
              recommendedProducts={recommendedProduct ? [recommendedProduct] : []}
            />
            {children}
          </PaymentStateContext.Provider>
        </Preview>
      </PreviewChrome>
    </PreviewSidebar>
  );
};
