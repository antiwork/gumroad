import * as React from "react";

import { Button } from "$app/components/Button";
import { type CartState, type CartItem, getDiscountedPrice, type Upsell } from "$app/components/Checkout/cartState";
import { computeOptionPrice, OptionRadioButton, type Option } from "$app/components/Product/ConfigurationSelector";

export type OfferedUpsell = Upsell & { item: CartItem; offeredOption: Option };

export const UpsellModal = ({
  upsell,
  accept,
  decline,
  cart,
}: {
  upsell: OfferedUpsell;
  accept: () => void;
  decline: () => void;
  cart: CartState;
}) => {
  const { item, offeredOption } = upsell;
  const product = item.product;
  const { discount } = getDiscountedPrice(cart, { ...item, option_id: offeredOption.id });
  return (
    <>
      <div className="flex flex-col gap-4">
        <h4 dangerouslySetInnerHTML={{ __html: upsell.description }} />
        <div className="radio-buttons" role="radiogroup">
          <OptionRadioButton
            selected
            priceCents={product.price_cents + computeOptionPrice(offeredOption, item.recurrence)}
            name={offeredOption.name}
            description={offeredOption.description}
            currencyCode={product.currency_code}
            isPWYW={product.is_tiered_membership ? offeredOption.is_pwyw : !!item.product.pwyw}
            discount={discount && discount.type !== "ppp" ? discount.value : null}
            recurrence={item.recurrence}
            product={product}
          />
        </div>
      </div>
      <footer style={{ display: "grid", gap: "var(--spacer-4)", gridTemplateColumns: "1fr 1fr" }}>
        <Button onClick={decline}>Don't upgrade</Button>
        <Button color="primary" onClick={accept}>
          Upgrade
        </Button>
      </footer>
    </>
  );
};
