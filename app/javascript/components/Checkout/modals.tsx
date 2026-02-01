import * as React from "react";

import { LineItemResult } from "$app/data/purchase";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";

import { Button } from "$app/components/Button";
import { CartItem, CartState, CrossSell, Upsell, getDiscountedPrice } from "$app/components/Checkout/cartState";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { computeOptionPrice, OptionRadioButton, Option } from "$app/components/Product/ConfigurationSelector";
import { PriceTag } from "$app/components/Product/PriceTag";
import { ProductCard, ProductCardFigure, ProductCardHeader, ProductCardFooter } from "$app/components/ui/ProductCard";

export type Result = { item: CartItem; result: LineItemResult };

export const CrossSellModal = ({
  crossSell,
  decline,
  accept,
  cart,
}: {
  crossSell: CrossSell;
  accept: () => void;
  decline: () => void;
  cart: CartState;
}) => {
  const product = crossSell.offered_product.product;
  const option = product.options.find(({ id }) => id === crossSell.offered_product.option_id);

  const crossSellCartItem: CartItem = {
    ...crossSell.offered_product,
    quantity: crossSell.offered_product.quantity || 1,
    url_parameters: {},
    referrer: "",
    recommender_model_name: null,
    accepted_offer: crossSell.discount ? { id: crossSell.id, discount: crossSell.discount } : null,
  };
  const { price: discountedPrice } = getDiscountedPrice(cart, crossSellCartItem);

  return (
    <>
      <div className="grid gap-4">
        <h4 dangerouslySetInnerHTML={{ __html: crossSell.description }} />
        <ProductCard className="lg:flex-row">
          <ProductCardFigure className="lg:w-56 lg:rounded-l lg:rounded-tr-none lg:border-r lg:border-b-0">
            {product.thumbnail_url ? <img src={product.thumbnail_url} /> : null}
          </ProductCardFigure>
          <section className="flex flex-1 flex-col overflow-hidden lg:gap-8 lg:px-6 lg:py-4">
            <ProductCardHeader className="lg:border-b-0 lg:p-0">
              <a className="stretched-link" href={product.url} target="_blank" rel="noreferrer">
                <h3 className="truncate">{option ? `${product.name} - ${option.name}` : product.name}</h3>
              </a>
              <AuthorByline
                name={product.creator.name}
                profileUrl={product.creator.profile_url}
                avatarUrl={product.creator.avatar_url}
              />
            </ProductCardHeader>
            <ProductCardFooter className="lg:divide-x-0">
              {crossSell.ratings ? (
                <div className="flex flex-[1_0_max-content] items-center gap-1 p-4 lg:p-0">
                  <span className="rating-average">{crossSell.ratings.average.toFixed(1)}</span>
                  <span>{`(${formatOrderOfMagnitude(crossSell.ratings.count, 1)})`}</span>
                </div>
              ) : null}
              <div className="p-4 lg:p-0">
                <PriceTag
                  currencyCode={product.currency_code}
                  oldPrice={
                    discountedPrice < crossSell.offered_product.price ? crossSell.offered_product.price : undefined
                  }
                  price={discountedPrice}
                  recurrence={
                    product.recurrences
                      ? {
                          id: product.recurrences.default,
                          duration_in_months: product.duration_in_months,
                        }
                      : undefined
                  }
                  isPayWhatYouWant={product.is_tiered_membership ? !!option?.is_pwyw : !!product.pwyw}
                  isSalesLimited={false}
                  creatorName={product.creator.name}
                  tooltipPosition="top"
                />
              </div>
            </ProductCardFooter>
          </section>
        </ProductCard>
      </div>
      <footer style={{ display: "grid", gap: "var(--spacer-4)", gridTemplateColumns: "1fr 1fr" }}>
        <Button onClick={decline}>
          {crossSell.replace_selected_products ? "Don't upgrade" : "Continue without adding"}
        </Button>
        <Button color="primary" onClick={accept}>
          {crossSell.replace_selected_products ? "Upgrade" : "Add to cart"}
        </Button>
      </footer>
    </>
  );
};

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
