import { parseISO } from "date-fns";
import * as React from "react";

import { formatDate } from "$app/utils/date";

import { ComboBox } from "$app/components/ComboBox";
import { Icon } from "$app/components/Icons";
import { useProductEditContext, Variant } from "$app/components/ProductEdit/state";

function HeaderActions({
  selectedVariantId,
  setSelectedVariantId,
  setConfirmingDiscardVariantContent,
}: {
  selectedVariantId: string | null;
  setSelectedVariantId: (variantId: string | null) => void;
  setConfirmingDiscardVariantContent: (value: boolean) => void;
}) {
  const { product, updateProduct } = useProductEditContext();
  const selectedVariant = product.variants.find((variant) => variant.id === selectedVariantId);

  const setHasSameRichContent = (value: boolean) => {
    if (value) {
      updateProduct((product) => {
        product.has_same_rich_content_for_all_variants = true;
        if (!product.rich_content.length) product.rich_content = selectedVariant?.rich_content ?? [];
        for (const variant of product.variants) variant.rich_content = [];
      });
    } else {
      updateProduct((product) => {
        product.has_same_rich_content_for_all_variants = false;
        if (product.rich_content.length > 0) {
          for (const variant of product.variants) variant.rich_content = product.rich_content;
          product.rich_content = [];
        }
      });
    }
  };

  return product.variants.length > 0 ? (
    <>
      <hr className="relative left-1/2 my-2 w-screen max-w-none -translate-x-1/2 border-border lg:hidden" />
      <ComboBox<Variant>
        // TODO: Currently needed to get the icon on the selected option even though this is not multiple select. We should fix this in the design system
        multiple
        input={(props) => (
          <div {...props} className="input h-full min-h-auto" aria-label="Select a version">
            <span className="fake-input text-singleline">
              {selectedVariant && !product.has_same_rich_content_for_all_variants
                ? `Editing: ${selectedVariant.name || "Untitled"}`
                : "Editing: All versions"}
            </span>
            <Icon name="outline-cheveron-down" />
          </div>
        )}
        options={product.variants}
        option={(item, props, index) => (
          <>
            <div
              {...props}
              onClick={(e) => {
                props.onClick?.(e);
                setSelectedVariantId(item.id);
              }}
              aria-selected={item.id === selectedVariantId}
              inert={product.has_same_rich_content_for_all_variants}
            >
              <div>
                <h4>{item.name || "Untitled"}</h4>
                {item.id === selectedVariant?.id ? (
                  <small>Editing</small>
                ) : product.has_same_rich_content_for_all_variants || item.rich_content.length ? (
                  <small>
                    Last edited on{" "}
                    {formatDate(
                      (product.has_same_rich_content_for_all_variants
                        ? product.rich_content
                        : item.rich_content
                      ).reduce<Date | null>((acc, item) => {
                        const date = parseISO(item.updated_at);
                        return acc && acc > date ? acc : date;
                      }, null) ?? new Date(),
                    )}
                  </small>
                ) : (
                  <small className="text-muted">No content yet</small>
                )}
              </div>
            </div>
            {index === product.variants.length - 1 ? (
              <div className="option">
                <label style={{ alignItems: "center" }}>
                  <input
                    type="checkbox"
                    checked={product.has_same_rich_content_for_all_variants}
                    onChange={() => {
                      if (!product.has_same_rich_content_for_all_variants && product.variants.length > 1)
                        return setConfirmingDiscardVariantContent(true);
                      setHasSameRichContent(!product.has_same_rich_content_for_all_variants);
                    }}
                  />
                  <small>Use the same content for all versions</small>
                </label>
              </div>
            ) : null}
          </>
        )}
      />
    </>
  ) : null;
}

export default HeaderActions;
