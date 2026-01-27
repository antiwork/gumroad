import * as React from "react";

import { variantLabel } from "$app/utils/labels";

import { BundleProduct } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import {
  CartItemEnd,
  CartItemFooter,
  CartItemMain,
  CartItemMedia,
  CartItemTitle,
  CartItem,
} from "$app/components/CartItemList";
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { ConfigurationSelector, PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { Thumbnail } from "$app/components/Product/Thumbnail";

export const BundleProductItem = ({
  bundleProduct,
  updateBundleProduct,
  removeBundleProduct,
}: {
  bundleProduct: BundleProduct;
  updateBundleProduct: (update: Partial<BundleProduct>) => void;
  removeBundleProduct: () => void;
}) => {
  const selectedVariant = bundleProduct.variants?.list.find(
    (variant) => variant.id === bundleProduct.variants?.selected_id,
  );
  const [selection, setSelection] = React.useState<PriceSelection>({
    optionId: bundleProduct.variants?.selected_id ?? null,
    quantity: bundleProduct.quantity,
    rent: false,
    price: { error: false, value: null },
    recurrence: null,
    callStartTime: null,
    payInInstallments: false,
  });

  return (
    <CartItem key={bundleProduct.id} isBundleItem>
      <CartItemMedia className="h-20 w-20">
        <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
      </CartItemMedia>
      <CartItemMain className="h-20">
        <CartItemTitle>{bundleProduct.name}</CartItemTitle>
        <span className="sr-only">Qty: {bundleProduct.quantity}</span>
        {selectedVariant ? (
          <CartItemFooter>
            <span className="line-clamp-1">
              <strong>{variantLabel(bundleProduct.native_type)}:</strong> {selectedVariant.name}
            </span>
          </CartItemFooter>
        ) : null}
      </CartItemMain>
      <CartItemEnd className="flex-row items-center gap-4 p-4">
        {bundleProduct.is_quantity_enabled || bundleProduct.variants ? (
          <Popover>
            <PopoverTrigger className="underline">Configure</PopoverTrigger>
            <PopoverContent>
              <div className="flex w-96 flex-col gap-4">
                <ConfigurationSelector
                  selection={selection}
                  setSelection={setSelection}
                  product={{
                    permalink: bundleProduct.permalink,
                    options:
                      bundleProduct.variants?.list.map((variant) => ({
                        id: variant.id,
                        name: variant.name,
                        quantity_left: null,
                        description: variant.description,
                        price_difference_cents: null,
                        recurrence_price_values: null,
                        is_pwyw: false,
                        duration_in_minutes: null,
                      })) ?? [],
                    is_quantity_enabled: bundleProduct.is_quantity_enabled,
                    rental: null,
                    currency_code: "usd",
                    price_cents: 0,
                    is_tiered_membership: false,
                    is_legacy_subscription: false,
                    is_multiseat_license: false,
                    quantity_remaining: null,
                    recurrences: null,
                    pwyw: null,
                    installment_plan: null,
                    ppp_details: null,
                    native_type: bundleProduct.native_type,
                  }}
                  discount={null}
                  hidePrices
                />
                <PopoverClose asChild>
                  <Button
                    color="accent"
                    onClick={() => {
                      updateBundleProduct({
                        variants: bundleProduct.variants && {
                          ...bundleProduct.variants,
                          selected_id: selection.optionId ?? bundleProduct.variants.selected_id,
                        },
                        quantity: selection.quantity,
                      });
                    }}
                  >
                    Apply
                  </Button>
                </PopoverClose>
              </div>
            </PopoverContent>
          </Popover>
        ) : null}
        <button className="cursor-pointer underline all-unset" onClick={removeBundleProduct}>
          Remove
        </button>
      </CartItemEnd>
    </CartItem>
  );
};
