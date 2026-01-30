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
import { Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { Product, ProfileSection, ExistingFileEntry, ShippingCountry } from "$app/components/ProductEdit/state";

type ContentPageProps = {
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

type ContentFormData = {
  has_same_rich_content_for_all_variants: boolean;
  rich_content: Page[];
  variants: Array<{ id: string; rich_content: Page[] }>;
  publish?: boolean;
  unpublish?: boolean;
  redirect_to?: string;
};

export default function ProductsEditContent() {
  const page = usePage();
  const props = cast<ContentPageProps>(page.props);
  const { product, id, unique_permalink } = props;

  const form = useForm<ContentFormData>({
    has_same_rich_content_for_all_variants: product.has_same_rich_content_for_all_variants,
    rich_content: product.rich_content,
    variants: product.variants.map((v) => ({ id: v.id, rich_content: v.rich_content })),
  });

  const transformContentData = () => ({
    has_same_rich_content_for_all_variants: form.data.has_same_rich_content_for_all_variants,
    rich_content: form.data.rich_content,
    variants: form.data.variants,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}, options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformContentData(), ...additionalData }));
    form.put(Routes.product_edit_content_path(unique_permalink), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = () => submitForm();
  const handleUnpublish = () => submitForm({ unpublish: true });
  const handlePublish = () => submitForm({ publish: true });
  const saveBeforeNavigate = (targetPath: string) => {
    if (!form.isDirty) return false;
    submitForm({ redirect_to: targetPath });
    return true;
  };

  return (
    <ProductEditLayout
      id={id}
      name={product.name}
      customPermalink={product.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={product.is_published}
      nativeType={product.native_type}
      currentTab="content"
      isProcessing={form.processing}
      {...(product.is_published && { onSave: handleSave })}
      {...(product.is_published && { onUnpublish: handleUnpublish })}
      {...(!product.is_published && { onSave: handleSave })}
      {...(!product.is_published && { onPublish: handlePublish })}
      onBeforeNavigate={saveBeforeNavigate}
    >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Content</h2>
              <p>
                Add the content your customers will receive after purchase. You can add files, text, images, and more.
              </p>
            </header>
            {/* Content editor will be rendered here */}
            {/* For now, show a placeholder since ContentTab has complex dependencies */}
            <div className="rounded bg-filled p-4">
              <p className="text-muted">
                Content editor is being migrated. Use the current implementation at{" "}
                <a href={`/products/${unique_permalink}/edit/content`}>the old edit page</a>.
              </p>
            </div>
          </section>
        </form>
      </div>
    </ProductEditLayout>
  );
}
