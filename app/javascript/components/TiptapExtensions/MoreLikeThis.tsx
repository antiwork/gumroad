import { Node as TiptapNode } from "@tiptap/core";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { getRecommendedProducts, RecommendationType } from "$app/data/recommended_products";
import { CardProduct } from "$app/parsers/product";

import { Icon } from "$app/components/Icons";
import { Card } from "$app/components/Product/Card";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

export const MoreLikeThis = TiptapNode.create<{ productId: string }>({
  name: "moreLikeThis",
  group: "block",
  atom: true,
  draggable: true,

  addAttributes() {
    return {
      productId: { default: null },
      recommendationType: { default: "own_products" },
    };
  },

  parseHTML() {
    return [{ tag: "moreLikeThis" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["moreLikeThis", HTMLAttributes];
  },

  addNodeView() {
    return ReactNodeViewRenderer(MoreLikeThisNodeView);
  },
});

const MoreLikeThisNodeView = ({ editor, node, extension, selected }: NodeViewProps) => {
  const [recommendedProducts, setRecommendedProducts] = React.useState<CardProduct[] | null>(null);
  const [isLoading, setIsLoading] = React.useState(true);
  const recommendationType = cast<RecommendationType | undefined>(node.attrs.recommendationType);

  React.useEffect(() => {
    const fetchRecommendedProducts = async () => {
      setIsLoading(true);
      try {
        const results = await getRecommendedProducts(
          [cast<{ productId: string }>(extension.options).productId],
          3,
          recommendationType,
        );
        setRecommendedProducts(results);
      } catch {
        setRecommendedProducts([]);
      }
      setIsLoading(false);
    };

    void fetchRecommendedProducts();
  }, [node.attrs.recommendationType]);

  const handleRecommendationTypeChange = (newType: RecommendationType) => {
    if (editor.can().updateAttributes("moreLikeThis", { recommendationType: newType })) {
      editor.chain().focus().updateAttributes("moreLikeThis", { recommendationType: newType }).run();
    }
  };

  return (
    <NodeViewWrapper>
      <div className={cx({ selected })}>
        {editor.isEditable ? (
          <NodeActionsMenu
            editor={editor}
            actions={[
              {
                item: () => (
                  <>
                    <Icon name="gear" />
                    <span>Settings</span>
                  </>
                ),
                menu: (close) => (
                  <>
                    <div role="menuitem" style={{ pointerEvents: "none", backgroundColor: "transparent" }}>
                      <b>More like this recommendations:</b>
                    </div>
                    <div onChange={close}>
                      <div role="menuitem">
                        <label>
                          <input
                            type="radio"
                            checked={node.attrs.recommendationType === "own_products"}
                            onChange={() => handleRecommendationTypeChange("own_products")}
                          />
                          Only my products
                        </label>
                      </div>
                      <div role="menuitem">
                        <label>
                          <input
                            type="radio"
                            checked={node.attrs.recommendationType === "directly_affiliated_products"}
                            onChange={() => handleRecommendationTypeChange("directly_affiliated_products")}
                          />
                          My products and affiliated
                        </label>
                      </div>
                      <div role="menuitem">
                        <label>
                          <input
                            type="radio"
                            checked={node.attrs.recommendationType === "gumroad_affiliates_products"}
                            onChange={() => handleRecommendationTypeChange("gumroad_affiliates_products")}
                          />
                          All products via
                          <a href="/help/article/249-affiliate-faq" target="_blank" rel="noreferrer">
                            Gumroad Affiliates
                          </a>
                        </label>
                      </div>
                    </div>
                  </>
                ),
              },
            ]}
          />
        ) : null}
        <h2>Customers who bought this product also bought</h2>
        <br />
        {isLoading ? (
          <ProductCardGrid narrow>
            {Array.from({ length: 3 }).map((_, index) => (
              <div key={index} className="dummy h-128" />
            ))}
          </ProductCardGrid>
        ) : recommendedProducts && recommendedProducts.length > 0 ? (
          <ProductCardGrid narrow inert={editor.isEditable}>
            {recommendedProducts.map((product) => (
              <div key={product.id}>
                <Card product={product} />
              </div>
            ))}
          </ProductCardGrid>
        ) : (
          <div className="placeholder">
            <Icon name="archive-fill" />
            <p>No products found</p>
          </div>
        )}
      </div>
    </NodeViewWrapper>
  );
};
