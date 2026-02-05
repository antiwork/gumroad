import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/ProductEdit/Layout";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";
import { CustomReceiptTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomReceiptTextInput";
import { CustomViewContentButtonTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomViewContentButtonTextInput";

type ReceiptPageProps = {
  product: {
    custom_receipt_text: string | null;
    custom_view_content_button_text: string | null;
    custom_receipt_text_max_length: number;
    custom_view_content_button_text_max_length: number;
    name: string;
  };
  id: string;
  unique_permalink: string;
};

export default function ReceiptPage() {
  const { product, unique_permalink } = usePage<ReceiptPageProps>().props;

  const form = useForm({
    custom_receipt_text: product.custom_receipt_text ?? "",
    custom_view_content_button_text: product.custom_view_content_button_text ?? "",
  });

  const [contentUpdates, setContentUpdates] = React.useState<{ uniquePermalinkOrVariantIds: string[] } | null>(null);

  const handleSave = () => {
    form.patch(Routes.products_edit_receipt_path(unique_permalink), {
      preserveScroll: true,
      onSuccess: () => {
        setContentUpdates({
          uniquePermalinkOrVariantIds: [unique_permalink],
        });
      },
    });
  };

  const handleSaveBeforeNavigate = (targetUrl: string) => {
    if (!form.isDirty) return false;
    form.transform((data) => ({
      ...data,
      redirect_to: targetUrl,
    }));
    form.patch(Routes.products_edit_receipt_path(unique_permalink), { preserveScroll: true });
    return true;
  };

  return (
    <Layout
      preview={
        <ReceiptPreview
          uniquePermalink={unique_permalink}
          custom_receipt_text={form.data.custom_receipt_text}
          custom_view_content_button_text={form.data.custom_view_content_button_text}
        />
      }
      previewScaleFactor={1}
      showBorder={false}
      showNavigationButton={false}
      currentTab="receipt"
      onSave={handleSave}
      isSaving={form.processing}
      contentUpdates={contentUpdates}
      setContentUpdates={setContentUpdates}
      onBeforeNavigate={handleSaveBeforeNavigate}
    >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <CustomViewContentButtonTextInput
              value={form.data.custom_view_content_button_text}
              onChange={(value) => form.setData("custom_view_content_button_text", value)}
              maxLength={product.custom_view_content_button_text_max_length}
            />
            <CustomReceiptTextInput
              value={form.data.custom_receipt_text}
              onChange={(value) => form.setData("custom_receipt_text", value)}
              maxLength={product.custom_receipt_text_max_length}
            />
          </section>
        </form>
      </div>
    </Layout>
  );
}
