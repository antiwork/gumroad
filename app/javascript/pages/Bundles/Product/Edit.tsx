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

import { BundleEditLayout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { BundleProduct } from "$app/components/BundleEdit/types";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Seller } from "$app/components/Product";
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
import { PublicFileWithStatus } from "$app/components/ProductEdit/state";
import { Switch } from "$app/components/ui/Switch";

type ProductPageProps = {
  bundle: {
    name: string;
    description: string;
    custom_permalink: string | null;
    covers: AssetPreview[];
    collaborating_user: Seller | null;
    customizable_price: boolean;
    price_cents: number;
    suggested_price_cents: number | null;
    eligible_for_installment_plans: boolean;
    allow_installment_plan: boolean;
    installment_plan: { number_of_installments: number } | null;
    max_purchase_count: number | null;
    quantity_enabled: boolean;
    should_show_sales_count: boolean;
    is_epublication: boolean;
    product_refund_policy_enabled: boolean;
    custom_button_text_option: CustomButtonTextOption | null;
    custom_summary: string | null;
    custom_attributes: Attribute[];
    refund_policy: RefundPolicy;
    display_product_reviews: boolean;
    public_files: PublicFileWithStatus[];
    audio_previews_enabled: boolean;
    is_published: boolean;
    products: BundleProduct[];
  };
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  refund_policies: OtherRefundPolicy[];
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
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

export default function BundlesProductEdit() {
  const page = usePage();
  const props = cast<ProductPageProps>(page.props);
  const {
    bundle,
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
  const currentSeller = useCurrentSeller();
  const url = useProductUrl(unique_permalink, bundle.custom_permalink);

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail ?? null);
  const [initialBundle] = React.useState(bundle);
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);
  const [publicFiles, setPublicFiles] = React.useState(bundle.public_files);

  const { isUploading, setImagesUploading } = useImageUpload();

  const updatePublicFiles = React.useCallback((updater: (prev: typeof publicFiles) => void) => {
    setPublicFiles((prev) => {
      const next = [...prev];
      updater(next);
      return next;
    });
  }, []);

  const form = useForm<ProductFormData>({
    name: bundle.name,
    description: bundle.description,
    custom_permalink: bundle.custom_permalink,
    price_cents: bundle.price_cents,
    customizable_price: bundle.customizable_price,
    suggested_price_cents: bundle.suggested_price_cents,
    max_purchase_count: bundle.max_purchase_count,
    quantity_enabled: bundle.quantity_enabled,
    should_show_sales_count: bundle.should_show_sales_count,
    is_epublication: bundle.is_epublication,
    product_refund_policy_enabled: bundle.product_refund_policy_enabled,
    custom_button_text_option: bundle.custom_button_text_option,
    custom_summary: bundle.custom_summary,
    custom_attributes: bundle.custom_attributes,
    covers: bundle.covers,
    refund_policy: bundle.refund_policy,
    allow_installment_plan: bundle.allow_installment_plan,
    installment_plan: bundle.installment_plan,
  });

  if (!currentSeller) return null;

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
    form.put(Routes.bundle_product_path(id), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = () => submitForm();
  const handleSaveAndContinue = () => submitForm();
  const handleUnpublish = () => submitForm({ unpublish: true });
  const handlePreview = () => {
    form.transform(() => transformProductData());
    form.put(Routes.bundle_product_path(id), {
      preserveScroll: true,
      onSuccess: () => window.open(url),
    });
  };
  const saveBeforeNavigate = (targetPath: string) => {
    if (!form.isDirty) return false;
    submitForm({ redirect_to: targetPath });
    return true;
  };

  // Build preview bundle from form data
  const previewBundle = {
    ...bundle,
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
    <BundleEditLayout
      id={id}
      name={form.data.name}
      customPermalink={form.data.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={bundle.is_published}
      publicFiles={publicFiles}
      preview={
        <ProductPreview
          bundle={previewBundle}
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
      {...(bundle.is_published && { onSave: handleSave })}
      {...(bundle.is_published && { onUnpublish: handleUnpublish })}
      {...(!bundle.is_published && { onSaveAndContinue: handleSaveAndContinue })}
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
            initialDescription={initialBundle.description}
            onChange={(description) => form.setData("description", description)}
            setImagesUploading={setImagesUploading}
            publicFiles={publicFiles}
            updatePublicFiles={updatePublicFiles}
            audioPreviewsEnabled={bundle.audio_previews_enabled}
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
            eligibleForInstallmentPlans={bundle.eligible_for_installment_plans}
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
            <Switch
              checked={form.data.quantity_enabled}
              onChange={(e) => form.setData("quantity_enabled", e.target.checked)}
              label="Allow customers to choose a quantity"
            />
            <Switch
              checked={form.data.should_show_sales_count}
              onChange={(e) => form.setData("should_show_sales_count", e.target.checked)}
              label="Publicly show the number of sales on your product page"
            />
            <Switch
              checked={form.data.is_epublication}
              onChange={(e) => form.setData("is_epublication", e.target.checked)}
              label={
                <>
                  Mark product as e-publication for VAT purposes{" "}
                  <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                    Learn more
                  </a>
                </>
              }
            />
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
