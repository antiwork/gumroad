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
import { ProductCard, ProductCardFigure, ProductCardHeader, ProductCardFooter } from "$app/components/ui/ProductCard";
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
  thumbnail_url: string | null;
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
  <ProductCardHeader className="lg:border-b-0 lg:p-0">
    <h3 className="truncate">
      {product.name}
      {variant ? <span className="ml-2 truncate text-muted">({variant.name})</span> : null}
    </h3>
  </ProductCardHeader>
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
          <ProductCard className="lg:h-32 lg:flex-row">
            <ProductCardFigure className="lg:h-full lg:rounded-l lg:rounded-tr-none lg:border-r lg:border-b-0">
              <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
            </ProductCardFigure>
            <section className="flex flex-1 flex-col lg:gap-8 lg:px-6 lg:py-4">
              {isEditable ? (
                <UpsellCardHeader product={product} variant={variant} />
              ) : (
                <a href={getUpsellUrl(id ?? "", product.permalink)} className="stretched-link">
                  <UpsellCardHeader product={product} variant={variant} />
                </a>
              )}
              <ProductCardFooter className="lg:divide-x-0">
                {product.review_count > 0 ? (
                  <div className="flex flex-[1_0_max-content] items-center gap-1 p-4 lg:p-0">
                    <Icon name="solid-star" />
                    <span className="rating-average">{product.average_rating.toFixed(1)}</span>
                    <span>{`(${formatOrderOfMagnitude(product.review_count, 1)})`}</span>
                  </div>
                ) : (
                  <div className="flex flex-1 items-center p-4 lg:p-0">No reviews</div>
                )}
                <div className="p-4 lg:p-0">
                  <PriceTag
                    currencyCode={product.currency_code}
                    oldPrice={oldPrice}
                    price={price}
                    isPayWhatYouWant={false}
                    isSalesLimited={false}
                  />
                </div>
              </ProductCardFooter>
            </section>
          </ProductCard>
        ) : null}
      </div>
      <NodeViewContent />
    </NodeViewWrapper>
  );
};
