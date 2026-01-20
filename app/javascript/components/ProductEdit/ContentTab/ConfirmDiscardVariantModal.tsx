import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { titleWithFallback } from "$app/components/ProductEdit/ContentTab/PageTab";
import { useProductEditContext } from "$app/components/ProductEdit/state";

function ConfirmDiscardVariantModal({
  selectedVariantId,
  confirmingDiscardVariantContent,
  setConfirmingDiscardVariantContent,
}: {
  selectedVariantId: string | null;
  confirmingDiscardVariantContent: boolean;
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

  return (
    <Modal
      open={confirmingDiscardVariantContent}
      onClose={() => setConfirmingDiscardVariantContent(false)}
      title="Discard content from other versions?"
      footer={
        <>
          <Button onClick={() => setConfirmingDiscardVariantContent(false)}>No, cancel</Button>
          <Button
            color="danger"
            onClick={() => {
              setHasSameRichContent(true);
              setConfirmingDiscardVariantContent(false);
            }}
          >
            Yes, proceed
          </Button>
        </>
      }
    >
      If you proceed, the content from all other versions of this product will be removed and replaced with the content
      of "{titleWithFallback(selectedVariant?.name)}".
      <strong>This action is irreversible.</strong>
    </Modal>
  );
}

export default ConfirmDiscardVariantModal;
