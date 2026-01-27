import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CUSTOM_BUTTON_TEXT_OPTIONS } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Bundle } from "$app/components/BundleEdit/state";
import { BundleEditLayout } from "$app/components/BundleEdit/InertiaLayout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { AttributesEditor } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { CoverEditor } from "$app/components/ProductEdit/ProductTab/CoverEditor";
import { CustomButtonTextOptionInput } from "$app/components/ProductEdit/ProductTab/CustomButtonTextOptionInput";
import { CustomPermalinkInput } from "$app/components/ProductEdit/ProductTab/CustomPermalinkInput";
import { CustomSummaryInput } from "$app/components/ProductEdit/ProductTab/CustomSummaryInput";
import { DescriptionEditor, useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { MaxPurchaseCountToggle } from "$app/components/ProductEdit/ProductTab/MaxPurchaseCountToggle";
import { PriceEditor } from "$app/components/ProductEdit/ProductTab/PriceEditor";
import { ThumbnailEditor } from "$app/components/ProductEdit/ProductTab/ThumbnailEditor";
import { RefundPolicySelector, RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";
import { Thumbnail } from "$app/data/thumbnails";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { RatingsWithPercentages } from "$app/parsers/product";
import { showAlert } from "$app/components/server-components/Alert";

type Props = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  refund_policies: OtherRefundPolicy[];
  products_count: number;
  is_bundle: boolean;
  has_outdated_purchases: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

export default function BundleProductEdit() {
  const props = cast<Props>(usePage().props);
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail: initialThumbnail,
    refund_policies,
    seller_refund_policy_enabled,
    is_bundle,
  } = props;

  const uid = React.useId();
  const currentSeller = useCurrentSeller();

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail);
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  const { isUploading, setImagesUploading } = useImageUpload();

  const form = useForm({
    name: initialBundle.name,
    description: initialBundle.description,
    custom_permalink: initialBundle.custom_permalink,
    price_cents: initialBundle.price_cents,
    suggested_price_cents: initialBundle.suggested_price_cents,
    customizable_price: initialBundle.customizable_price,
    eligible_for_installment_plans: initialBundle.eligible_for_installment_plans,
    allow_installment_plan: initialBundle.allow_installment_plan,
    installment_plan: initialBundle.installment_plan,
    custom_button_text_option: initialBundle.custom_button_text_option,
    custom_summary: initialBundle.custom_summary,
    custom_attributes: initialBundle.custom_attributes,
    covers: initialBundle.covers,
    max_purchase_count: initialBundle.max_purchase_count,
    quantity_enabled: initialBundle.quantity_enabled,
    should_show_sales_count: initialBundle.should_show_sales_count,
    is_epublication: initialBundle.is_epublication,
    product_refund_policy_enabled: initialBundle.product_refund_policy_enabled,
    refund_policy: initialBundle.refund_policy,
    public_files: initialBundle.public_files,
  });

  React.useEffect(() => {
    if (!is_bundle) {
      showAlert("Select products and save your changes to finish converting this product to a bundle.", "warning");
    }
  }, [is_bundle]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    form.put(Routes.bundles_product_path(id), {
      preserveScroll: true,
    });
  };

  if (!currentSeller) return null;

  // Create a bundle object for preview compatibility
  const bundleForPreview: Bundle = {
    ...initialBundle,
    ...form.data,
  };

  return (
    <BundleEditLayout
      bundleId={id}
      bundleName={form.data.name}
      uniquePermalink={unique_permalink}
      isPublished={initialBundle.is_published}
      currentTab="product"
      preview={<ProductPreview 
        bundle={bundleForPreview} 
        showRefundPolicyModal={showRefundPolicyPreview}
        id={id}
        uniquePermalink={unique_permalink}
        currencyType={currency_type}
        salesCountForInventory={props.sales_count_for_inventory}
        ratings={props.ratings}
        sellerRefundPolicyEnabled={seller_refund_policy_enabled}
        sellerRefundPolicy={props.seller_refund_policy}
      />}
      isLoading={isUploading}
    >
      <form onSubmit={handleSubmit}>
        <section className="p-4! md:p-8!">
          <fieldset>
            <label htmlFor={`${uid}-name`}>Name</label>
            <input
              id={`${uid}-name`}
              type="text"
              value={form.data.name}
              onChange={(evt) => form.setData("name", evt.target.value)}
            />
            {form.errors.name && <div className="error">{form.errors.name}</div>}
          </fieldset>
          <DescriptionEditor
            id={id}
            initialDescription={initialBundle.description}
            onChange={(description) => form.setData("description", description)}
            setImagesUploading={setImagesUploading}
            publicFiles={form.data.public_files}
            updatePublicFiles={(updater) => {
              const currentFiles = [...form.data.public_files];
              updater(currentFiles);
              form.setData("public_files", currentFiles);
            }}
            audioPreviewsEnabled={initialBundle.audio_previews_enabled}
          />
          <CustomPermalinkInput
            value={form.data.custom_permalink}
            onChange={(value) => form.setData("custom_permalink", value)}
            uniquePermalink={unique_permalink}
            url={Routes.short_link_url(form.data.custom_permalink ?? unique_permalink, {
              host: currentSeller.subdomain,
            })}
          />
        </section>
        <section className="p-4! md:p-8!">
          <h2>Pricing</h2>
          <PriceEditor
            priceCents={form.data.price_cents}
            suggestedPriceCents={form.data.suggested_price_cents}
            isPWYW={form.data.customizable_price}
            setPriceCents={(priceCents) =>
              form.setData({
                ...form.data,
                price_cents: priceCents,
                ...(priceCents === 0 && { customizable_price: true }),
              })
            }
            setSuggestedPriceCents={(suggestedPriceCents) =>
              form.setData("suggested_price_cents", suggestedPriceCents)
            }
            setIsPWYW={(isPWYW) => form.setData("customizable_price", isPWYW)}
            currencyType={currency_type}
            eligibleForInstallmentPlans={form.data.eligible_for_installment_plans}
            allowInstallmentPlan={form.data.allow_installment_plan}
            numberOfInstallments={form.data.installment_plan?.number_of_installments ?? null}
            onAllowInstallmentPlanChange={(allowed) => form.setData("allow_installment_plan", allowed)}
            onNumberOfInstallmentsChange={(value) =>
              form.setData("installment_plan", {
                ...form.data.installment_plan,
                number_of_installments: value,
              })
            }
          />
        </section>
        <ThumbnailEditor
          covers={form.data.covers}
          thumbnail={thumbnail}
          setThumbnail={setThumbnail}
          permalink={unique_permalink}
          nativeType="bundle"
        />
        <CoverEditor
          covers={form.data.covers}
          setCovers={(covers) => form.setData("covers", covers)}
          permalink={unique_permalink}
        />
        <section className="p-4! md:p-8!">
          <h2>Product info</h2>
          <CustomButtonTextOptionInput
            value={form.data.custom_button_text_option}
            onChange={(value) => form.setData("custom_button_text_option", value)}
            options={CUSTOM_BUTTON_TEXT_OPTIONS}
          />
          <CustomSummaryInput
            value={form.data.custom_summary}
            onChange={(value) => form.setData("custom_summary", value)}
          />
          <AttributesEditor
            customAttributes={form.data.custom_attributes}
            setCustomAttributes={(custom_attributes) => form.setData("custom_attributes", custom_attributes)}
          />
        </section>
        <section className="p-4! md:p-8!">
          <h2>Settings</h2>
          <fieldset>
            <MaxPurchaseCountToggle
              maxPurchaseCount={form.data.max_purchase_count}
              setMaxPurchaseCount={(value) => form.setData("max_purchase_count", value)}
            />
            <Toggle value={form.data.quantity_enabled} onChange={(newValue) => form.setData("quantity_enabled", newValue)}>
              Allow customers to choose a quantity
            </Toggle>
            <Toggle
              value={form.data.should_show_sales_count}
              onChange={(newValue) => form.setData("should_show_sales_count", newValue)}
            >
              Publicly show the number of sales on your product page
            </Toggle>
            <Toggle value={form.data.is_epublication} onChange={(newValue) => form.setData("is_epublication", newValue)}>
              Mark product as e-publication for VAT purposes{" "}
              <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </Toggle>
            {!seller_refund_policy_enabled ? (
              <RefundPolicySelector
                refundPolicy={form.data.refund_policy}
                setRefundPolicy={(newValue) => form.setData("refund_policy", newValue)}
                refundPolicies={refund_policies}
                isEnabled={form.data.product_refund_policy_enabled}
                setIsEnabled={(newValue) => form.setData("product_refund_policy_enabled", newValue)}
                setShowPreview={setShowRefundPolicyPreview}
              />
            ) : null}
          </fieldset>
        </section>
      </form>
    </BundleEditLayout>
  );
}
