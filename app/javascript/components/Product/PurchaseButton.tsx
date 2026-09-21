import * as React from "react";

import { formatBuyerLocalOrSetPrice } from "$app/utils/currency";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import {
  applySelection,
  ConfigurationSelectorHandle,
  PriceSelection,
} from "$app/components/Product/ConfigurationSelector";
import { CtaButton } from "$app/components/Product/CtaButton";
import { needsOptionChoice } from "$app/components/Product/purchaseReadiness";
import { SubscriptionChoiceModal } from "$app/components/Product/SubscriptionChoiceModal";
import { showAlert } from "$app/components/server-components/Alert";

type Props = Omit<React.ComponentPropsWithoutRef<typeof CtaButton>, "onClick"> & {
  setSelection?: React.Dispatch<React.SetStateAction<PriceSelection>> | undefined;
  configurationSelectorRef?: React.RefObject<ConfigurationSelectorHandle> | undefined;
};

export const PurchaseButton = React.forwardRef<HTMLAnchorElement, Props>(
  ({ setSelection, configurationSelectorRef, ...props }, ref) => {
    const { product, purchase, selection, discountCode } = props;
    const loggedInUser = useLoggedInUser();
    const [checkoutUrlForModal, setCheckoutUrlForModal] = React.useState<string | null>(null);
    const { isPWYW, discountedPriceCents } = applySelection(
      product,
      discountCode?.valid ? discountCode.discount : null,
      selection,
    );

    const validate = () => {
      if (needsOptionChoice(product, selection)) {
        configurationSelectorRef?.current?.scrollIntoView({ block: "nearest" });
        configurationSelectorRef?.current?.focusRequiredInput();
        return false;
      }
      if (isPWYW && (selection.price.value === null || selection.price.value < discountedPriceCents)) {
        configurationSelectorRef?.current?.scrollIntoView({ block: "nearest" });
        setSelection?.({ ...selection, price: { ...selection.price, error: true } });
        if (selection.price.value === null) {
          configurationSelectorRef?.current?.focusRequiredInput();
          showAlert("You must input an amount", "warning");
        } else if (selection.price.value < discountedPriceCents) {
          const formattedMinPrice = formatBuyerLocalOrSetPrice(
            discountedPriceCents,
            {
              currencyCode: product.currency_code,
              buyerCurrency: product.buyer_currency,
              buyerLocalCurrencyRate: product.buyer_local_currency_rate,
              buyerLocalCurrencySubunitToUnit: product.buyer_local_currency_subunit_to_unit,
            },
            { symbolFormat: "short" },
          );
          configurationSelectorRef?.current?.focusRequiredInput();
          showAlert(`Minimum price for this product is ${formattedMinPrice}.`, "error");
        }
        return false;
      }
      if (product.native_type === "call" && !selection.callStartTime) {
        showAlert("You must select a date and time for the call", "warning");
        return false;
      }
      return true;
    };

    return (
      <>
        <CtaButton
          {...props}
          ref={ref}
          onClick={(e) => {
            if (!validate()) {
              e.preventDefault();
              return;
            }
            if (
              loggedInUser &&
              purchase &&
              (purchase.membership || purchase.subscription_has_lapsed) &&
              product.is_recurring_billing
            ) {
              e.preventDefault();
              setCheckoutUrlForModal(e.currentTarget.href);
            }
          }}
        />
        {purchase && (purchase.membership || purchase.subscription_has_lapsed) && product.is_recurring_billing ? (
          <SubscriptionChoiceModal
            purchase={purchase}
            checkoutUrl={checkoutUrlForModal ?? ""}
            onClose={() => setCheckoutUrlForModal(null)}
          />
        ) : null}
      </>
    );
  },
);
PurchaseButton.displayName = "PurchaseButton";
