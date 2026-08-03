import * as React from "react";

import { Button } from "$app/components/Button";
import { type CartState, type CartItem, getDiscountedPrice, type Upsell } from "$app/components/Checkout/cartState";
import { computeOptionPrice, OptionRadioButton, type Option } from "$app/components/Product/ConfigurationSelector";
import { Tabs } from "$app/components/ui/Tabs";

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
  const offeredPriceCents = product.price_cents + computeOptionPrice(offeredOption, item.recurrence);
  const { discount } = getDiscountedPrice(
    cart,
    { ...item, price: offeredPriceCents, option_id: offeredOption.id },
    item,
  );
  const hasOncePerCartDiscount =
    discount?.type === "code" && discount.value.type === "fixed" && discount.value.once_per_cart;
  return (
    <>
      <div className="flex flex-col gap-4">
        <h4 dangerouslySetInnerHTML={{ __html: upsell.description }} />
        <Tabs variant="buttons" role="radiogroup">
          <OptionRadioButton
            selected
            priceCents={offeredPriceCents * (hasOncePerCartDiscount ? item.quantity : 1)}
            name={offeredOption.name}
            description={offeredOption.description}
            currencyCode={product.currency_code}
            isPWYW={product.is_tiered_membership ? offeredOption.is_pwyw : !!item.product.pwyw}
            discount={discount && discount.type !== "ppp" ? discount.value : null}
            recurrence={item.recurrence}
            product={product}
          />
        </Tabs>
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
