import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Seller } from "$app/components/Product";
import { ProductEditLayout } from "$app/components/ProductEdit/InertiaLayout";
import { CustomReceiptTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomReceiptTextInput";
import { CustomViewContentButtonTextInput } from "$app/components/ProductEdit/ReceiptTab/CustomViewContentButtonTextInput";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { Product, ProfileSection, ExistingFileEntry, ShippingCountry } from "$app/components/ProductEdit/state";

type ReceiptPageProps = {
  product: Product;
  id: string;
  unique_permalink: string;
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  currency_type: CurrencyCode;
  is_tiered_membership: boolean;
  is_listed_on_discover: boolean;
  is_physical: boolean;
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  earliest_membership_price_change_date: string;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  sales_count_for_inventory: number;
  successful_sales_count: number;
  ratings: RatingsWithPercentages;
  seller: Seller;
  existing_files: ExistingFileEntry[];
  aws_key: string;
  s3_url: string;
  available_countries: ShippingCountry[];
  google_client_id: string;
  google_calendar_enabled: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellation_discounts_enabled: boolean;
  ai_generated: boolean;
};

type ReceiptFormData = {
  custom_view_content_button_text: string | null;
  custom_receipt_text: string | null;
};

export default function ProductsEditReceipt() {
  const page = usePage();
  const props = cast<ReceiptPageProps>(page.props);
  const { product, id, unique_permalink } = props;

  const form = useForm<ReceiptFormData>({
    custom_view_content_button_text: product.custom_view_content_button_text,
    custom_receipt_text: product.custom_receipt_text,
  });

  const submitForm = () => {
    if (form.processing) return;
    form.put(Routes.product_edit_receipt_path(unique_permalink), {
      preserveScroll: true,
    });
  };

  const handleSave = () => submitForm();

  return (
    <ProductEditLayout
      id={id}
      name={product.name}
      customPermalink={product.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={product.is_published}
      nativeType={product.native_type}
      currentTab="receipt"
      isProcessing={form.processing}
      onSave={handleSave}
      showBorder={false}
      showNavigationButton={false}
      previewScaleFactor={1}
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
    </ProductEditLayout>
  );
}
