import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Seller } from "$app/components/Product";

import { BaseProductEditPageProps } from "../Shared/types";
import { EditLayout } from "../Shared/EditLayout";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";
import { CustomReceiptTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomReceiptTextInput";
import { CustomViewContentButtonTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomViewContentButtonTextInput";

type ReceiptPageProps = BaseProductEditPageProps & {
  product: {
    name: string;
    custom_view_content_button_text: string | null;
    custom_view_content_button_text_max_length: number;
    custom_receipt_text: string | null;
    custom_receipt_text_max_length: number;
    is_published?: boolean;
    native_type?: string;
  };
  seller: Seller;
};

type ReceiptFormData = {
  custom_view_content_button_text: string | null;
  custom_receipt_text: string | null;
};

export default function ProductsReceiptEdit() {
  const page = usePage();
  const props = cast<ReceiptPageProps>(page.props);
  const { product: initialProduct, id, unique_permalink } = props;

  const form = useForm<ReceiptFormData>({
    custom_view_content_button_text: initialProduct.custom_view_content_button_text,
    custom_receipt_text: initialProduct.custom_receipt_text,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}, options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.put(Routes.product_receipt_path(id), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = () => submitForm();

  // Build preview product from form data
  const previewProduct = {
    ...initialProduct,
    ...form.data,
  } as any;

  return (
    <EditLayout
      productId={id}
      uniquePermalink={unique_permalink}
      currentTab="receipt"
      onSave={handleSave}
      isSaving={form.processing}
      product={previewProduct}
      preview={<ReceiptPreview />}
    >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <CustomViewContentButtonTextInput
              value={form.data.custom_view_content_button_text}
              onChange={(value) => form.setData("custom_view_content_button_text", value)}
              maxLength={initialProduct.custom_view_content_button_text_max_length}
            />
            <CustomReceiptTextInput
              value={form.data.custom_receipt_text}
              onChange={(value) => form.setData("custom_receipt_text", value)}
              maxLength={initialProduct.custom_receipt_text_max_length}
            />
          </section>
        </form>
      </div>
    </EditLayout>
  );
}
