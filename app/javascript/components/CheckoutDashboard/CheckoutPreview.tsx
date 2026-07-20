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
        surcharges: { type: "pending" },
        status: { type: "input", errors: new Set() },
        paymentMethod: "card",
        usStates: ["AA"],
        caProvinces: ["AA"],
        countries: { US: "United States" },
        tipOptions: [0, 15, 20, 25],
        savedCreditCard: null,
        checkoutPayment: {
          integration: "card_element",
          fallback_reason: "checkout_preview",
          disable_wallets: false,
          request_apple_pay_merchant_tokens: false,
          elements_options: null,
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
            canGift: true,
          },
        ],
        paypalClientId: "",
        recaptchaKey: "",
        recaptchaScoreBased: false,
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
