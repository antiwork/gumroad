import * as React from "react";

import { CardProduct } from "$app/parsers/product";

import { NavigationButton } from "$app/components/Button";
import { Checkout } from "$app/components/Checkout";
import { CartItem } from "$app/components/Checkout/cartState";
import { StateContext as PaymentStateContext, createReducer } from "$app/components/Checkout/payment";
import { useAppDomain } from "$app/components/DomainSettings";
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

  const appDomain = useAppDomain();
  const checkoutUrl = Routes.checkout_url({ host: appDomain });

  return (
    <PreviewSidebar>
      {/* The dashboard's sample cart only exists here, so there's no live page that would
          show this exact preview — the chrome links to the real checkout page, which renders
          the buyer's actual cart. */}
      <PreviewChrome
        title="Checkout"
        url={checkoutUrl}
        link={(props) => <NavigationButton {...props} href={checkoutUrl} target="_blank" rel="noreferrer" />}
      >
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
