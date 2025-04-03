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
      insertUpsellCard: (options: { productId: string; discount: OfferCode | null }) => ReturnType;
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
};

export const UpsellCard = TiptapNode.create({
  name: "upsellCard",
  group: "block",
  selectable: true,
  draggable: true,
  atom: true,

  addAttributes() {
    return {
      productId: { default: null },
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
  const discount = cast<OfferCode | null>(node.attrs.discount);
  const [product, setProduct] = React.useState<Product | null>(null);
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
      } catch (error) {
        assertResponseError(error);
      } finally {
        setIsLoading(false);
      }
    };

    void fetchProduct();
  });

  const header = (
    <header>
      <h3>{product?.name}</h3>
    </header>
  );

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
          <div className="dummy" style={{ height: "8rem" }}></div>
        ) : product ? (
          <article className="product-card horizontal">
            <figure>
              <Thumbnail url={null} nativeType={product.native_type} />
            </figure>
            <section>
              {isEditable ? (
                header
              ) : (
                <a href={getUpsellUrl(id ?? "", product.permalink)} className="stretched-link">
                  {header}
                </a>
              )}
              <footer style={{ fontSize: "1rem" }}>
                {product.review_count > 0 ? (
                  <div className="rating">
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
                    oldPrice={discount ? product.price_cents : undefined}
                    price={discount ? applyOfferCodeToCents(discount, product.price_cents) : product.price_cents}
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
