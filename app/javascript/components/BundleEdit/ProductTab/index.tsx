import * as React from "react";

import { CUSTOM_BUTTON_TEXT_OPTIONS } from "$app/parsers/product";

import { Layout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { useBundleEditContext } from "$app/components/BundleEdit/state";
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
import { RefundPolicySelector } from "$app/components/ProductEdit/RefundPolicy";
import { Toggle } from "$app/components/Toggle";

export const ProductTab = () => {
  const {
    bundle,
    updateBundle,
    uniquePermalink,
    currencyType,
    thumbnail: initialThumbnail,
    refundPolicies,
    seller_refund_policy_enabled,
    id,
  } = useBundleEditContext();
  const uid = React.useId();

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail);

  const [initialBundle] = React.useState(bundle);

  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  const currentSeller = useCurrentSeller();

  const { isUploading, setImagesUploading } = useImageUpload();

  const url = useProductUrl();

  if (!currentSeller) return null;

  return (
    <Layout preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />} isLoading={isUploading}>
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
            updatePublicFiles={(updater) => updateBundle((bundle) => updater(bundle.public_files))}
            audioPreviewsEnabled={bundle.audio_previews_enabled}
          />
          <CustomPermalinkInput
            value={bundle.custom_permalink}
            onChange={(value) => updateBundle({ custom_permalink: value })}
            uniquePermalink={uniquePermalink}
            url={url}
          />
        </section>
        <section className="p-4! md:p-8!">
          <h2>Pricing</h2>
          <PriceEditor
            priceCents={bundle.price_cents}
            suggestedPriceCents={bundle.suggested_price_cents}
            isPWYW={bundle.customizable_price}
            setPriceCents={(priceCents) => updateBundle({ price_cents: priceCents })}
            setSuggestedPriceCents={(suggestedPriceCents) =>
              updateBundle({ suggested_price_cents: suggestedPriceCents })
            }
            setIsPWYW={(isPWYW) => updateBundle({ customizable_price: isPWYW })}
            currencyType={currencyType}
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
          permalink={uniquePermalink}
          nativeType="bundle"
        />
        <CoverEditor
          covers={bundle.covers}
          setCovers={(covers) => updateBundle({ covers })}
          permalink={uniquePermalink}
        />
        <section className="p-4! md:p-8!">
          <h2>Product info</h2>
          <CustomButtonTextOptionInput
            value={bundle.custom_button_text_option}
            onChange={(value) => updateBundle({ custom_button_text_option: value })}
            options={CUSTOM_BUTTON_TEXT_OPTIONS}
          />
          <CustomSummaryInput
            value={bundle.custom_summary}
            onChange={(value) => updateBundle({ custom_summary: value })}
          />
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
            <Toggle
              value={bundle.quantity_enabled}
              onChange={(newValue) => updateBundle({ quantity_enabled: newValue })}
            >
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
                refundPolicies={refundPolicies}
                isEnabled={bundle.product_refund_policy_enabled}
                setIsEnabled={(newValue) => updateBundle({ product_refund_policy_enabled: newValue })}
                setShowPreview={setShowRefundPolicyPreview}
              />
            ) : null}
          </fieldset>
        </section>
      </form>
    </Layout>
  );
};
