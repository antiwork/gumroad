import * as React from "react";

import { Layout, type ProductEditTab } from "$app/components/ProductEdit/Layout";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";
import { CustomReceiptTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomReceiptTextInput";
import { CustomViewContentButtonTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomViewContentButtonTextInput";
import { useProductEditContext } from "$app/components/ProductEdit/state";

export const ReceiptTab = ({ currentTab }: { currentTab: ProductEditTab }) => {
  const { product, updateProduct } = useProductEditContext();

  return (
    <Layout currentTab={currentTab} preview={<ReceiptPreview />} previewScaleFactor={1} showBorder={false} showNavigationButton={false}>
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <CustomViewContentButtonTextInput
              value={product.custom_view_content_button_text}
              onChange={(value) => updateProduct({ custom_view_content_button_text: value })}
              maxLength={product.custom_view_content_button_text_max_length}
            />
            <CustomReceiptTextInput
              value={product.custom_receipt_text}
              onChange={(value) => updateProduct({ custom_receipt_text: value })}
              maxLength={product.custom_receipt_text_max_length}
            />
          </section>
        </form>
      </div>
    </Layout>
  );
};
