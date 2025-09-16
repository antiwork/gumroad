import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { Checkout } from "$app/components/Checkout";
import { CartItem } from "$app/components/Checkout/cartState";
import { StateContext as PaymentStateContext, createReducer } from "$app/components/Checkout/payment";
import { Preview } from "$app/components/Preview";

export const CheckoutPreview = ({
  children,
  cartItem,
  recommendedProduct,
  className,
}: {
  children?: React.ReactNode;
  cartItem: CartItem;
  recommendedProduct?: CardProduct | undefined;
  className?: string;
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
        tipOptions: [0, 10, 20],
        savedCreditCard: null,
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
            nativeType: "digital",
            canGift: true,
          },
        ],
        paypalClientId: "",
        recaptchaKey: "",
      },
      () => undefined,
    ],
    [cartItem],
  );

  return (
    <aside aria-label="Preview" className={className}>
      <header>
        <h2>Preview</h2>
      </header>
      <Preview scaleFactor={0.4} style={{ border: "var(--border)" }}>
        <PaymentStateContext.Provider value={paymentState}>
          <Checkout
            discoverUrl=""
            cart={{
              items: [cartItem],
              discountCodes: [],
            }}
            recommendedProducts={recommendedProduct ? [recommendedProduct] : []}
          />
          {children}
        </PaymentStateContext.Provider>
      </Preview>
    </aside>
  );
};
