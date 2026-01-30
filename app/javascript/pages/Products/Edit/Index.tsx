import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import {
  AssetPreview,
  CustomButtonTextOption,
  CUSTOM_BUTTON_TEXT_OPTIONS,
  RatingsWithPercentages,
} from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Seller } from "$app/components/Product";
import { ProductEditLayout, useProductUrl } from "$app/components/ProductEdit/InertiaLayout";
import { Attribute, AttributesEditor } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { CoverEditor } from "$app/components/ProductEdit/ProductTab/CoverEditor";
import { CustomButtonTextOptionInput } from "$app/components/ProductEdit/ProductTab/CustomButtonTextOptionInput";
import { CustomPermalinkInput } from "$app/components/ProductEdit/ProductTab/CustomPermalinkInput";
import { CustomSummaryInput } from "$app/components/ProductEdit/ProductTab/CustomSummaryInput";
import { DescriptionEditor, useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { MaxPurchaseCountToggle } from "$app/components/ProductEdit/ProductTab/MaxPurchaseCountToggle";
import { PriceEditor } from "$app/components/ProductEdit/ProductTab/PriceEditor";
import { ThumbnailEditor } from "$app/components/ProductEdit/ProductTab/ThumbnailEditor";
import { RefundPolicy, RefundPolicySelector } from "$app/components/ProductEdit/RefundPolicy";
import { Product, ProfileSection, PublicFileWithStatus, ExistingFileEntry, ShippingCountry } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";

type ProductPageProps = {
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

type ProductFormData = {
  name: string;
  description: string;
  custom_permalink: string | null;
  price_cents: number;
  customizable_price: boolean;
  suggested_price_cents: number | null;
  max_purchase_count: number | null;
  quantity_enabled: boolean;
  should_show_sales_count: boolean;
  is_epublication: boolean;
  product_refund_policy_enabled: boolean;
  custom_button_text_option: CustomButtonTextOption | null;
  custom_summary: string | null;
  custom_attributes: Attribute[];
  covers: AssetPreview[];
  refund_policy: RefundPolicy;
  allow_installment_plan: boolean;
  installment_plan: { number_of_installments: number } | null;
  unpublish?: boolean;
  redirect_to?: string;
};

export default function ProductsEditIndex() {
  const page = usePage();
  const props = cast<ProductPageProps>(page.props);
  const {
    product,
    id,
    unique_permalink,
    currency_type,
    thumbnail: initialThumbnail,
    sales_count_for_inventory,
    ratings,
    refund_policies,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = props;

  const uid = React.useId();
  const url = useProductUrl(unique_permalink, product.custom_permalink, product.native_type);

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail ?? null);
  const [initialProduct] = React.useState(product);
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);
  const [publicFiles, setPublicFiles] = React.useState(product.public_files);

  const { isUploading, setImagesUploading } = useImageUpload();

  const updatePublicFiles = React.useCallback((updater: (prev: typeof publicFiles) => void) => {
    setPublicFiles((prev) => {
      const next = [...prev];
      updater(next);
      return next;
    });
  }, []);

  const form = useForm<ProductFormData>({
    name: product.name,
    description: product.description,
    custom_permalink: product.custom_permalink,
    price_cents: product.price_cents,
    customizable_price: product.customizable_price,
    suggested_price_cents: product.suggested_price_cents,
    max_purchase_count: product.max_purchase_count,
    quantity_enabled: product.quantity_enabled,
    should_show_sales_count: product.should_show_sales_count,
    is_epublication: product.is_epublication,
    product_refund_policy_enabled: product.product_refund_policy_enabled,
    custom_button_text_option: product.custom_button_text_option,
    custom_summary: product.custom_summary,
    custom_attributes: product.custom_attributes,
    covers: product.covers,
    refund_policy: product.refund_policy,
    allow_installment_plan: product.allow_installment_plan,
    installment_plan: product.installment_plan,
  });

  const transformProductData = () => ({
    name: form.data.name,
    description: form.data.description,
    custom_permalink: form.data.custom_permalink,
    price_cents: form.data.price_cents,
    customizable_price: form.data.customizable_price,
    suggested_price_cents: form.data.suggested_price_cents,
    max_purchase_count: form.data.max_purchase_count,
    quantity_enabled: form.data.quantity_enabled,
    should_show_sales_count: form.data.should_show_sales_count,
    is_epublication: form.data.is_epublication,
    product_refund_policy_enabled: form.data.product_refund_policy_enabled,
    seller_refund_policy_enabled,
    custom_button_text_option: form.data.custom_button_text_option,
    custom_summary: form.data.custom_summary,
    custom_attributes: form.data.custom_attributes,
    covers: form.data.covers.map(({ id }) => id),
    refund_policy: form.data.refund_policy,
    installment_plan: form.data.allow_installment_plan ? form.data.installment_plan : undefined,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}, options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformProductData(), ...additionalData }));
    form.put(Routes.product_edit_path(unique_permalink), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = () => submitForm();
  const handleSaveAndContinue = () => submitForm();
  const handleUnpublish = () => submitForm({ unpublish: true });
  const handlePreview = (e: React.MouseEvent) => {
    e.preventDefault();
    form.transform(() => transformProductData());
    form.put(Routes.product_edit_path(unique_permalink), {
      preserveScroll: true,
      onSuccess: () => window.open(url),
    });
  };
  const saveBeforeNavigate = (targetPath: string) => {
    if (!form.isDirty) return false;
    submitForm({ redirect_to: targetPath });
    return true;
  };

  // Build preview product from form data
  const previewProduct = {
    ...product,
    name: form.data.name,
    description: form.data.description,
    covers: form.data.covers,
    customizable_price: form.data.customizable_price,
    price_cents: form.data.price_cents,
    suggested_price_cents: form.data.suggested_price_cents,
    max_purchase_count: form.data.max_purchase_count,
    quantity_enabled: form.data.quantity_enabled,
    should_show_sales_count: form.data.should_show_sales_count,
    custom_button_text_option: form.data.custom_button_text_option,
    custom_summary: form.data.custom_summary,
    custom_attributes: form.data.custom_attributes,
    refund_policy: form.data.refund_policy,
    public_files: publicFiles,
  };

  return (
    <ProductEditLayout
      id={id}
      name={form.data.name}
      customPermalink={form.data.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={product.is_published}
      nativeType={product.native_type}
      currentTab="product"
      preview={
        <ProductPreviewWrapper
          product={previewProduct}
          id={id}
          uniquePermalink={unique_permalink}
          currencyType={currency_type}
          salesCountForInventory={sales_count_for_inventory}
          ratings={ratings}
          sellerRefundPolicyEnabled={seller_refund_policy_enabled}
          sellerRefundPolicy={seller_refund_policy}
          showRefundPolicyModal={showRefundPolicyPreview}
        />
      }
      isLoading={isUploading}
      isProcessing={form.processing}
      {...(product.is_published && { onSave: handleSave })}
      {...(product.is_published && { onUnpublish: handleUnpublish })}
      {...(!product.is_published && { onSaveAndContinue: handleSaveAndContinue })}
      onPreview={handlePreview}
      onBeforeNavigate={saveBeforeNavigate}
    >
      <form>
        <section className="p-4! md:p-8!">
          <fieldset>
            <label htmlFor={`${uid}-name`}>Name</label>
            <input
              id={`${uid}-name`}
              type="text"
              value={form.data.name}
              onChange={(evt) => form.setData("name", evt.target.value)}
            />
          </fieldset>
          <DescriptionEditor
            id={id}
            initialDescription={initialProduct.description}
            onChange={(description) => form.setData("description", description)}
            setImagesUploading={setImagesUploading}
            publicFiles={publicFiles}
            updatePublicFiles={updatePublicFiles}
            audioPreviewsEnabled={product.audio_previews_enabled}
          />
          <CustomPermalinkInput
            value={form.data.custom_permalink}
            onChange={(value) => form.setData("custom_permalink", value)}
            uniquePermalink={unique_permalink}
            url={url}
          />
        </section>
        <section className="p-4! md:p-8!">
          <h2>Pricing</h2>
          <PriceEditor
            priceCents={form.data.price_cents}
            suggestedPriceCents={form.data.suggested_price_cents}
            isPWYW={form.data.customizable_price}
            setPriceCents={(priceCents) =>
              form.setData((data) => ({
                ...data,
                price_cents: priceCents,
                ...(priceCents === 0 && { customizable_price: true }),
              }))
            }
            setSuggestedPriceCents={(suggestedPriceCents) => form.setData("suggested_price_cents", suggestedPriceCents)}
            setIsPWYW={(isPWYW) => form.setData("customizable_price", isPWYW)}
            currencyType={currency_type}
            eligibleForInstallmentPlans={product.eligible_for_installment_plans}
            allowInstallmentPlan={form.data.allow_installment_plan}
            numberOfInstallments={form.data.installment_plan?.number_of_installments ?? null}
            onAllowInstallmentPlanChange={(allowed) => form.setData("allow_installment_plan", allowed)}
            onNumberOfInstallmentsChange={(value) =>
              form.setData("installment_plan", { ...form.data.installment_plan, number_of_installments: value })
            }
          />
        </section>
        <ThumbnailEditor
          covers={form.data.covers}
          thumbnail={thumbnail}
          setThumbnail={setThumbnail}
          permalink={unique_permalink}
          nativeType={product.native_type}
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
            <Toggle
              value={form.data.quantity_enabled}
              onChange={(newValue) => form.setData("quantity_enabled", newValue)}
            >
              Allow customers to choose a quantity
            </Toggle>
            <Toggle
              value={form.data.should_show_sales_count}
              onChange={(newValue) => form.setData("should_show_sales_count", newValue)}
            >
              Publicly show the number of sales on your product page
            </Toggle>
            <Toggle
              value={form.data.is_epublication}
              onChange={(newValue) => form.setData("is_epublication", newValue)}
            >
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
    </ProductEditLayout>
  );
}

// Wrapper component for ProductPreview to avoid circular dependency
function ProductPreviewWrapper({
  product,
  id,
  uniquePermalink,
  currencyType,
  salesCountForInventory,
  ratings,
  sellerRefundPolicyEnabled,
  sellerRefundPolicy,
  showRefundPolicyModal,
}: {
  product: Product;
  id: string;
  uniquePermalink: string;
  currencyType: CurrencyCode;
  salesCountForInventory: number;
  ratings: RatingsWithPercentages;
  sellerRefundPolicyEnabled: boolean;
  sellerRefundPolicy: Pick<RefundPolicy, "title" | "fine_print">;
  showRefundPolicyModal: boolean;
}) {
  // ProductPreview expects a specific context, for now we'll render a simpler preview
  // TODO: Create a standalone preview component that doesn't depend on ProductEditContext
  return (
    <div className="preview-placeholder">
      <h3>{product.name || "Untitled"}</h3>
      {product.covers[0] ? (
        <img src={product.covers[0].url} alt={product.name} style={{ maxWidth: "100%", borderRadius: 8 }} />
      ) : null}
    </div>
  );
}
