import * as React from "react";

import { variantLabel } from "$app/utils/labels";

import { BundleProduct } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { Popover } from "$app/components/Popover";
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
  const [editPopoverOpen, setEditPopoverOpen] = React.useState(false);
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
    <div role="listitem" key={bundleProduct.id}>
      <section>
        <figure>
          <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
        </figure>
        <section>
          <h4>{bundleProduct.name}</h4>
          <footer>
            <ul>
              <li>
                <strong>Qty:</strong> {bundleProduct.quantity}
              </li>
              {selectedVariant ? (
                <li>
                  <strong>{variantLabel(bundleProduct.native_type)}:</strong> {selectedVariant.name}
                </li>
              ) : null}
            </ul>
          </footer>
        </section>
        <section>
          <footer>
            <ul>
              {bundleProduct.is_quantity_enabled || bundleProduct.variants ? (
                <li>
                  <Popover
                    trigger={<div className="link">Configure</div>}
                    open={editPopoverOpen}
                    onToggle={setEditPopoverOpen}
                  >
                    <div className="paragraphs" style={{ width: "24rem" }}>
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
                          setEditPopoverOpen(false);
                        }}
                      >
                        Apply
                      </Button>
                    </div>
                  </Popover>
                </li>
              ) : null}
              <li>
                <button className="underline" onClick={removeBundleProduct}>
                  Remove
                </button>
              </li>
            </ul>
          </footer>
        </section>
      </section>
    </div>
  );
};
