import { Node as TiptapNode } from "@tiptap/core";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { formatOrderOfMagnitude } from "$app/utils/formatOrderOfMagnitude";
import { OfferCode, applyOfferCodeToCents } from "$app/utils/offer-code";
import { assertResponseError, request } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { PriceTag } from "$app/components/Product/PriceTag";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import { useRunOnce } from "$app/components/useRunOnce";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    upsellCard: {
      insertUpsellCard: (options: {
        productId: string;
        variantId: string | null;
        discount: OfferCode | null;
      }) => ReturnType;
    };
  }
}

type Product = {
  id: string;
  name: string;
  price_cents: number;
  currency_code: CurrencyCode;
  review_count: number;
  average_rating: number;
  native_type: ProductNativeType;
  permalink: string;
  options: ProductOption[];
};

type ProductOption = {
  id: string;
  name: string;
  description: string;
  duration_in_minutes: number | null;
  price_difference_cents: number;
  is_pwyw: boolean;
};

type UpsellCardHeaderProps = {
  product: Product;
  variant: ProductOption | null;
};

const UpsellCardHeader = ({ product, variant }: UpsellCardHeaderProps) => (
  <header>
    <h3>
      {product.name}
      {variant ? <span className="text-muted ml-2">({variant.name})</span> : null}
    </h3>
  </header>
);

export const UpsellCard = TiptapNode.create({
  name: "upsellCard",
  group: "block",
  selectable: true,
  draggable: true,
  atom: true,

  addAttributes() {
    return {
      productId: { default: null },
      variantId: { default: null },
      discount: {
        default: null,
        parseHTML: (element) => {
          const discount = element.getAttribute("discount");
          return discount ? cast<OfferCode | null>(JSON.parse(discount)) : null;
        },
        renderHTML: (attributes) => {
          if (attributes.discount) {
            return { discount: JSON.stringify(attributes.discount) };
          }
          return {};
        },
      },
      id: { default: null },
    };
  },

  parseHTML() {
    return [{ tag: "upsell-card" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["upsell-card", HTMLAttributes];
  },

  addNodeView() {
    return ReactNodeViewRenderer(UpsellCardNodeView);
  },

  addCommands() {
    return {
      insertUpsellCard: createInsertCommand("upsellCard"),
    };
  },
});

const getUpsellUrl = (id: string, permalink: string) => {
  const url = new URL(Routes.checkout_index_url());
  const searchParams = new URLSearchParams();
  searchParams.append("product", permalink);
  searchParams.append("accepted_offer_id", id);
  url.search = searchParams.toString();
  return url.toString();
};

const UpsellCardNodeView = ({ node, selected, editor }: NodeViewProps) => {
  const id = cast<string | null>(node.attrs.id);
  const productId = cast<string>(node.attrs.productId);
  const variantId = cast<string | null>(node.attrs.variantId);
  const discount = cast<OfferCode | null>(node.attrs.discount);
  const [product, setProduct] = React.useState<Product | null>(null);
  const [variant, setVariant] = React.useState<ProductOption | null>(null);
  const [isLoading, setIsLoading] = React.useState(true);
  const nodeRef = React.useRef<HTMLDivElement>(null);
  const isEditable = editor.isEditable;

  useRunOnce(() => {
    const fetchProduct = async () => {
      try {
        const response = await request({
          method: "GET",
          accept: "json",
          url: Routes.checkout_upsells_product_path(productId),
        });
        const productData = cast<Product>(await response.json());
        setProduct(productData);
        setVariant(productData.options.find(({ id }) => id === variantId) || null);
      } catch (error) {
        assertResponseError(error);
      } finally {
        setIsLoading(false);
      }
    };

    void fetchProduct();
  });

  const variantPrice = variant ? variant.price_difference_cents : 0;
  const productPrice = product ? product.price_cents + variantPrice : 0;
  const oldPrice = discount ? productPrice : undefined;
  const price = discount ? applyOfferCodeToCents(discount, productPrice) : productPrice;

  return (
    <NodeViewWrapper>
      <div
        ref={nodeRef}
        className="upsell-card"
        style={{
          outline: selected && isEditable ? "2px solid rgb(var(--accent))" : "none",
          borderRadius: "var(--border-radius-1)",
          display: "grid",
          gap: "var(--spacer-4)",
          position: "relative",
        }}
        data-drag-handle
      >
        {isLoading ? (
          <div className="dummy h-32"></div>
        ) : product ? (
          <article className="product-card horizontal">
            <figure>
              <Thumbnail url={null} nativeType={product.native_type} />
            </figure>

            <section>
              {isEditable ? (
                <UpsellCardHeader product={product} variant={variant} />
              ) : (
                <a href={getUpsellUrl(id ?? "", product.permalink)} className="stretched-link">
                  <UpsellCardHeader product={product} variant={variant} />
                </a>
              )}
              <footer className="text-base">
                {product.review_count > 0 ? (
                  <div className="flex shrink-0 items-center gap-1">
                    <Icon name="solid-star" />
                    <span className="rating-average">{product.average_rating.toFixed(1)}</span>
                    <span>{`(${formatOrderOfMagnitude(product.review_count, 1)})`}</span>
                  </div>
                ) : (
                  <div>No reviews</div>
                )}
                <div>
                  <PriceTag
                    currencyCode={product.currency_code}
                    oldPrice={oldPrice}
                    price={price}
                    isPayWhatYouWant={false}
                    isSalesLimited={false}
                  />
                </div>
              </footer>
            </section>
          </article>
        ) : null}
      </div>
      <NodeViewContent />
    </NodeViewWrapper>
  );
};
