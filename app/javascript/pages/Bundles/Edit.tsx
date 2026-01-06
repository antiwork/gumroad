import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { CUSTOM_BUTTON_TEXT_OPTIONS, RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { InertiaLayout, useProductUrl } from "$app/components/BundleEdit/InertiaLayout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { Bundle, BundleEditContext } from "$app/components/BundleEdit/state";
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
import { RefundPolicy, RefundPolicySelector } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";

export type BundleEditProps = {
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

export default function BundleEdit() {
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail: initialThumbnail,
    refund_policies,
    seller_refund_policy_enabled,
    taxonomies,
    profile_sections,
    ratings,
    sales_count_for_inventory,
    products_count,
    has_outdated_purchases,
    seller_refund_policy,
  } = cast<BundleEditProps>(usePage().props);

  const [bundle, setBundle] = React.useState(initialBundle);
  React.useEffect(() => setBundle(initialBundle), [initialBundle]);
  const updateBundle = (update: Partial<Bundle> | ((bundle: Bundle) => void)) =>
    setBundle((prevBundle) => {
      if (typeof update === "function") {
        const updated = { ...prevBundle };
        update(updated);
        return updated;
      }
      return { ...prevBundle, ...update };
    });

  const uid = React.useId();
  const [thumbnail, setThumbnail] = React.useState(initialThumbnail);
  React.useEffect(() => setThumbnail(initialThumbnail), [initialThumbnail]);
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  const currentSeller = useCurrentSeller();
  const { isUploading, setImagesUploading } = useImageUpload();
  const url = useProductUrl(bundle, unique_permalink);

  // Provide context for components that still need it (like ProductPreview)
  const contextValue = React.useMemo(
    () => ({
      bundle,
      updateBundle,
      id,
      uniquePermalink: unique_permalink,
      currencyType: currency_type,
      thumbnail,
      salesCountForInventory: sales_count_for_inventory,
      ratings,
      taxonomies,
      profileSections: profile_sections,
      refundPolicies: refund_policies,
      productsCount: products_count,
      hasOutdatedPurchases: has_outdated_purchases,
      seller_refund_policy_enabled,
      seller_refund_policy,
    }),
    [bundle, thumbnail],
  );

  if (!currentSeller) return null;

  return (
    <BundleEditContext.Provider value={contextValue}>
      <InertiaLayout
        currentTab="product"
        bundle={bundle}
        id={id}
        uniquePermalink={unique_permalink}
        onBundleChange={updateBundle}
        isLoading={isUploading}
        preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />}
      >
        <form>
          <section className="p-4! md:p-8!">
            <fieldset>
              <label htmlFor={`${uid}-name`}>Name</label>
              <input
                id={`${uid}-name`}
                type="text"
                value={bundle.name}
                onChange={(evt) => updateBundle({ name: evt.target.value })}
              />
            </fieldset>
            <DescriptionEditor
              id={id}
              initialDescription={initialBundle.description}
              onChange={(description) => updateBundle({ description })}
              setImagesUploading={setImagesUploading}
              publicFiles={bundle.public_files}
              updatePublicFiles={(updater) =>
                setBundle((prev) => {
                  const newFiles = [...prev.public_files];
                  updater(newFiles);
                  return { ...prev, public_files: newFiles };
                })
              }
              audioPreviewsEnabled={bundle.audio_previews_enabled}
            />
            <CustomPermalinkInput
              value={bundle.custom_permalink}
              onChange={(value) => updateBundle({ custom_permalink: value })}
              uniquePermalink={unique_permalink}
              url={url}
            />
          </section>
          <section className="p-4! md:p-8!">
            <h2>Pricing</h2>
            <PriceEditor
              priceCents={bundle.price_cents}
              suggestedPriceCents={bundle.suggested_price_cents}
              isPWYW={bundle.customizable_price}
              setPriceCents={(priceCents) =>
                updateBundle({
                  price_cents: priceCents,
                  ...(priceCents === 0 && { customizable_price: true }),
                })
              }
              setSuggestedPriceCents={(suggestedPriceCents) => updateBundle({ suggested_price_cents: suggestedPriceCents })}
              setIsPWYW={(isPWYW) => updateBundle({ customizable_price: isPWYW })}
              currencyType={currency_type}
              eligibleForInstallmentPlans={bundle.eligible_for_installment_plans}
              allowInstallmentPlan={bundle.allow_installment_plan}
              numberOfInstallments={bundle.installment_plan?.number_of_installments ?? null}
              onAllowInstallmentPlanChange={(allowed) => updateBundle({ allow_installment_plan: allowed })}
              onNumberOfInstallmentsChange={(value) =>
                updateBundle({
                  installment_plan: { ...bundle.installment_plan, number_of_installments: value },
                })
              }
            />
          </section>
          <ThumbnailEditor
            covers={bundle.covers}
            thumbnail={thumbnail}
            setThumbnail={setThumbnail}
            permalink={unique_permalink}
            nativeType="bundle"
          />
          <CoverEditor
            covers={bundle.covers}
            setCovers={(covers) => updateBundle({ covers })}
            permalink={unique_permalink}
          />
          <section className="p-4! md:p-8!">
            <h2>Product info</h2>
            <CustomButtonTextOptionInput
              value={bundle.custom_button_text_option}
              onChange={(value) => updateBundle({ custom_button_text_option: value })}
              options={CUSTOM_BUTTON_TEXT_OPTIONS}
            />
            <CustomSummaryInput value={bundle.custom_summary} onChange={(value) => updateBundle({ custom_summary: value })} />
            <AttributesEditor
              customAttributes={bundle.custom_attributes}
              setCustomAttributes={(custom_attributes) => updateBundle({ custom_attributes })}
            />
          </section>
          <section className="p-4! md:p-8!">
            <h2>Settings</h2>
            <fieldset>
              <MaxPurchaseCountToggle
                maxPurchaseCount={bundle.max_purchase_count}
                setMaxPurchaseCount={(value) => updateBundle({ max_purchase_count: value })}
              />
              <Toggle value={bundle.quantity_enabled} onChange={(newValue) => updateBundle({ quantity_enabled: newValue })}>
                Allow customers to choose a quantity
              </Toggle>
              <Toggle
                value={bundle.should_show_sales_count}
                onChange={(newValue) => updateBundle({ should_show_sales_count: newValue })}
              >
                Publicly show the number of sales on your product page
              </Toggle>
              <Toggle value={bundle.is_epublication} onChange={(newValue) => updateBundle({ is_epublication: newValue })}>
                Mark product as e-publication for VAT purposes{" "}
                <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                  Learn more
                </a>
              </Toggle>
              {!seller_refund_policy_enabled ? (
                <RefundPolicySelector
                  refundPolicy={bundle.refund_policy}
                  setRefundPolicy={(newValue) => updateBundle({ refund_policy: newValue })}
                  refundPolicies={refund_policies}
                  isEnabled={bundle.product_refund_policy_enabled}
                  setIsEnabled={(newValue) => updateBundle({ product_refund_policy_enabled: newValue })}
                  setShowPreview={setShowRefundPolicyPreview}
                />
              ) : null}
            </fieldset>
          </section>
        </form>
      </InertiaLayout>
    </BundleEditContext.Provider>
  );
}
