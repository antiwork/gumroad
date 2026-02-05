import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { type OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { type Thumbnail } from "$app/data/thumbnails";
import { COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS, CUSTOM_BUTTON_TEXT_OPTIONS } from "$app/parsers/product";
import { type CurrencyCode, currencyCodeList } from "$app/utils/currency";
import { recurrenceIds, recurrenceLabels } from "$app/utils/recurringPricing";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import CustomDomain from "$app/components/CustomDomain";
import { Icon } from "$app/components/Icons";
import { Layout, useProductUrl } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { AttributesEditor } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { AvailabilityEditor } from "$app/components/ProductEdit/ProductTab/AvailabilityEditor";
import { BundleConversionNotice } from "$app/components/ProductEdit/ProductTab/BundleConversionNotice";
import { CallLimitationsEditor } from "$app/components/ProductEdit/ProductTab/CallLimitationsEditor";
import { CancellationDiscountSelector } from "$app/components/ProductEdit/ProductTab/CancellationDiscountSelector";
import { CircleIntegrationEditor } from "$app/components/ProductEdit/ProductTab/CircleIntegrationEditor";
import { CoverEditor } from "$app/components/ProductEdit/ProductTab/CoverEditor";
import { CustomButtonTextOptionInput } from "$app/components/ProductEdit/ProductTab/CustomButtonTextOptionInput";
import { CustomPermalinkInput } from "$app/components/ProductEdit/ProductTab/CustomPermalinkInput";
import { CustomSummaryInput } from "$app/components/ProductEdit/ProductTab/CustomSummaryInput";
import { DescriptionEditor, useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { DiscordIntegrationEditor } from "$app/components/ProductEdit/ProductTab/DiscordIntegrationEditor";
import { DurationEditor } from "$app/components/ProductEdit/ProductTab/DurationEditor";
import { DurationsEditor } from "$app/components/ProductEdit/ProductTab/DurationsEditor";
import { FreeTrialSelector } from "$app/components/ProductEdit/ProductTab/FreeTrialSelector";
import { GoogleCalendarIntegrationEditor } from "$app/components/ProductEdit/ProductTab/GoogleCalendarIntegrationEditor";
import { MaxPurchaseCountToggle } from "$app/components/ProductEdit/ProductTab/MaxPurchaseCountToggle";
import { PriceEditor } from "$app/components/ProductEdit/ProductTab/PriceEditor";
import { ShippingDestinationsEditor } from "$app/components/ProductEdit/ProductTab/ShippingDestinationsEditor";
import { SuggestedAmountsEditor } from "$app/components/ProductEdit/ProductTab/SuggestedAmountsEditor";
import { ThumbnailEditor } from "$app/components/ProductEdit/ProductTab/ThumbnailEditor";
import { TiersEditor } from "$app/components/ProductEdit/ProductTab/TiersEditor";
import { VersionsEditor } from "$app/components/ProductEdit/ProductTab/VersionsEditor";
import { RefundPolicySelector } from "$app/components/ProductEdit/RefundPolicy";
import { type Product } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Alert } from "$app/components/ui/Alert";
import { Switch } from "$app/components/ui/Switch";

type Props = {
  product: Product;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  is_physical: boolean;
  google_calendar_enabled: boolean;
  google_client_id: string;
  cancellation_discounts_enabled: boolean;
  ai_generated: boolean;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  ratings: {
    count: number;
    average: number;
    percentages: [number, number, number, number, number];
  };
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: {
    title: string;
    fine_print: string;
  };
  sales_count_for_inventory: number;
  successful_sales_count: number;
};

type ProductFormData = Product & {
  currency_type?: CurrencyCode;
  redirect_to?: string;
};

export default function ProductEditPage() {
  const props = usePage<Props>().props;
  const currentSeller = useCurrentSeller();
  const uid = React.useId();

  // Initialize form with typed product and defaults for optional arrays
  const form = useForm<ProductFormData>({
    ...props.product,
    covers: props.product.covers,
    custom_attributes: props.product.custom_attributes,
    file_attributes: props.product.file_attributes,
    shipping_destinations: props.product.shipping_destinations,
    availabilities: props.product.availabilities,
  });

  const [currencyType, setCurrencyType] = React.useState<CurrencyCode>(props.currency_type);
  const [thumbnail, setThumbnail] = React.useState<Thumbnail | null>(props.thumbnail);
  const [showAiNotification, setShowAiNotification] = React.useState(props.ai_generated);
  const [contentUpdates, setContentUpdates] = React.useState<{ uniquePermalinkOrVariantIds: string[] } | null>(null);
  const { isUploading, setImagesUploading } = useImageUpload();
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  const updateProductPartial = (partial: Partial<Product>) => {
    Object.keys(partial).forEach((key) => {
      const value = partial[key];
      if (value !== undefined) form.setData(key, value);
    });
  };

  const updateProductVia = (updater: (product: Product) => void) => {
    const updated: Product = { ...form.data };
    updater(updated);
    Object.keys(updated).forEach((key) => {
      form.setData(key, updated[key]);
    });
  };

  const handleSave = () => {
    form.transform((data) => ({
      ...data,
      currency_type: currencyType,
    }));

    form.patch(Routes.products_edit_product_path(props.unique_permalink), {
      preserveScroll: true,
      onSuccess: () => {
        setContentUpdates({
          uniquePermalinkOrVariantIds: [props.unique_permalink],
        });
      },
    });
  };

  const handleSaveBeforeNavigate = (targetUrl: string) => {
    if (!form.isDirty) return false;
    form.transform((data) => ({
      ...data,
      currency_type: currencyType,
      redirect_to: targetUrl,
    }));
    form.patch(Routes.products_edit_product_path(props.unique_permalink), { preserveScroll: true });
    return true;
  };

  const productData = form.data;
  const nativeType = productData.native_type;
  const isCoffee = nativeType === "coffee";

  const url = useProductUrl();
  if (!currentSeller) return null;

  return (
    <Layout
      preview={
        <ProductPreview
          product={form.data}
          id={props.id}
          uniquePermalink={props.unique_permalink}
          currencyType={currencyType}
          showRefundPolicyModal={showRefundPolicyPreview}
          salesCountForInventory={props.sales_count_for_inventory}
          successfulSalesCount={props.successful_sales_count}
          ratings={props.ratings}
          seller_refund_policy_enabled={props.seller_refund_policy_enabled}
          seller_refund_policy={props.seller_refund_policy}
        />
      }
      isLoading={isUploading}
      currentTab="product"
      onSave={handleSave}
      isSaving={form.processing}
      contentUpdates={contentUpdates}
      setContentUpdates={setContentUpdates}
      onBeforeNavigate={handleSaveBeforeNavigate}
    >
      <div className="squished">
        <form onSubmit={(e) => e.preventDefault()}>
          <section className="p-4! md:p-8!">
            {showAiNotification ? (
              <Alert role="status" variant="accent">
                <div className="flex items-center gap-4">
                  <Icon className="text-lg" name="sparkle" />
                  <div className="flex-1">
                    <strong>Your AI product is ready!</strong> Take a moment to check out the product and content tabs.
                    Tweak things and make it your own—this is your time to shine!
                  </div>
                  <button
                    type="button"
                    className="cursor-pointer self-center underline all-unset"
                    onClick={() => setShowAiNotification(false)}
                  >
                    close
                  </button>
                </div>
              </Alert>
            ) : null}
            <BundleConversionNotice product={productData} id={props.id} />
            <fieldset>
              <label htmlFor={`${uid}-name`}>{isCoffee ? "Header" : "Name"}</label>
              <input
                id={`${uid}-name`}
                type="text"
                value={form.data.name}
                onChange={(evt) => form.setData("name", evt.target.value)}
              />
            </fieldset>
            {productData.native_type === "coffee" ? (
              <>
                <fieldset>
                  <label htmlFor={`${uid}-body`}>Body</label>
                  <textarea
                    id={`${uid}-body`}
                    value={form.data.description}
                    placeholder="Add a short inspiring message"
                    onChange={(evt) => form.setData("description", evt.target.value)}
                  />
                </fieldset>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-url`}>URL</label>
                    <CopyToClipboard text={url}>
                      <button type="button" className="cursor-pointer font-normal underline all-unset">
                        Copy URL
                      </button>
                    </CopyToClipboard>
                  </legend>
                  <input id={`${uid}-url`} type="text" value={url} disabled />
                </fieldset>
              </>
            ) : (
              <>
                <DescriptionEditor
                  id={props.id}
                  initialDescription={props.product.description}
                  onChange={(description) => form.setData("description", description)}
                  setImagesUploading={setImagesUploading}
                  publicFiles={form.data.public_files}
                  updatePublicFiles={(updater) => {
                    const updated = [...form.data.public_files];
                    updater(updated);
                    form.setData("public_files", updated);
                  }}
                  audioPreviewsEnabled={form.data.audio_previews_enabled}
                />
                <CustomPermalinkInput
                  value={form.data.custom_permalink}
                  onChange={(value) => form.setData("custom_permalink", value)}
                  uniquePermalink={props.unique_permalink}
                  url={url}
                />
              </>
            )}
          </section>
          {productData.native_type === "coffee" ? (
            <>
              <section className="p-4! md:p-8!">
                <h2>Pricing</h2>
                <SuggestedAmountsEditor
                  versions={productData.variants}
                  onChange={(variants) => form.setData("variants", variants)}
                  currencyType={currencyType}
                />
              </section>
              <section className="p-4! md:p-8!">
                <h2>Settings</h2>
                <CustomButtonTextOptionInput
                  value={form.data.custom_button_text_option}
                  onChange={(value) => form.setData("custom_button_text_option", value)}
                  options={COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS}
                />
              </section>
            </>
          ) : (
            <>
              <CoverEditor
                covers={form.data.covers}
                setCovers={(covers) => form.setData("covers", covers)}
                permalink={props.unique_permalink}
              />
              <ThumbnailEditor
                covers={form.data.covers}
                thumbnail={thumbnail}
                setThumbnail={setThumbnail}
                permalink={props.unique_permalink}
                nativeType={props.product.native_type}
              />
              <section className="p-4! md:p-8!">
                <h2>Product info</h2>
                {productData.native_type !== "membership" ? (
                  <CustomButtonTextOptionInput
                    value={form.data.custom_button_text_option}
                    onChange={(value) => form.setData("custom_button_text_option", value)}
                    options={CUSTOM_BUTTON_TEXT_OPTIONS}
                  />
                ) : null}
                <CustomSummaryInput
                  value={form.data.custom_summary}
                  onChange={(value) => form.setData("custom_summary", value)}
                />
                <AttributesEditor
                  customAttributes={form.data.custom_attributes}
                  setCustomAttributes={(custom_attributes) => form.setData("custom_attributes", custom_attributes)}
                  fileAttributes={form.data.file_attributes}
                  setFileAttributes={(file_attributes) => form.setData("file_attributes", file_attributes)}
                />
              </section>
              <section className="p-4! md:p-8!">
                <h2>Integrations</h2>
                <fieldset>
                  {form.data.community_chat_enabled === null ? null : (
                    <ToggleSettingRow
                      label="Invite your customers to your Gumroad community chat"
                      value={form.data.community_chat_enabled}
                      onChange={(newValue) => form.setData("community_chat_enabled", newValue)}
                      help={{
                        label: "Learn more",
                        url: "/help/article/347-gumroad-community",
                      }}
                    />
                  )}
                  <CircleIntegrationEditor
                    integration={form.data.integrations.circle}
                    onChange={(newIntegration) =>
                      form.setData("integrations", {
                        ...form.data.integrations,
                        circle: newIntegration,
                      })
                    }
                    product={form.data}
                    updateProduct={updateProductVia}
                  />
                  <DiscordIntegrationEditor
                    integration={form.data.integrations.discord}
                    onChange={(newIntegration) =>
                      form.setData("integrations", {
                        ...form.data.integrations,
                        discord: newIntegration,
                      })
                    }
                    product={form.data}
                    updateProduct={updateProductVia}
                  />
                  {productData.native_type === "call" && props.google_calendar_enabled ? (
                    <GoogleCalendarIntegrationEditor
                      integration={form.data.integrations.google_calendar}
                      onChange={(newIntegration) =>
                        form.setData("integrations", {
                          ...form.data.integrations,
                          google_calendar: newIntegration,
                        })
                      }
                      googleClientId={props.google_client_id}
                      updateProduct={updateProductVia}
                    />
                  ) : null}
                </fieldset>
              </section>
              {productData.native_type === "membership" ? (
                <section className="p-4! md:p-8!">
                  <h2>Tiers</h2>
                  <TiersEditor
                    tiers={productData.variants}
                    onChange={(variants) => form.setData("variants", variants)}
                    product={productData}
                    currencyType={currencyType}
                    unique_permalink={props.unique_permalink}
                  />
                </section>
              ) : (
                <>
                  <section className="p-4! md:p-8!">
                    <h2>Pricing</h2>
                    <PriceEditor
                      priceCents={form.data.price_cents}
                      suggestedPriceCents={form.data.suggested_price_cents}
                      isPWYW={form.data.customizable_price}
                      setPriceCents={(priceCents) => {
                        form.setData("price_cents", priceCents);
                        if (priceCents === 0) form.setData("customizable_price", true);
                      }}
                      setSuggestedPriceCents={(suggestedPriceCents) =>
                        form.setData("suggested_price_cents", suggestedPriceCents)
                      }
                      currencyCodeSelector={{
                        options: currencyCodeList,
                        onChange: (code) => setCurrencyType(code),
                      }}
                      setIsPWYW={(isPWYW) => form.setData("customizable_price", isPWYW)}
                      currencyType={currencyType}
                      eligibleForInstallmentPlans={props.product.eligible_for_installment_plans}
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
                    {productData.native_type === "commission" ? (
                      <p
                        style={{
                          marginTop: "var(--spacer-2)",
                          fontSize: "var(--font-size-small)",
                          color: "var(--color-text-secondary)",
                        }}
                      >
                        Commission products use a 50% deposit upfront, 50% upon completion payment split.
                      </p>
                    ) : null}
                  </section>
                  {productData.native_type === "call" ? (
                    <>
                      <section className="p-4! md:p-8!">
                        <div style={{ display: "flex", justifyContent: "space-between" }}>
                          <h2>Durations</h2>
                          <a
                            href="https://gumroad.com/help/article/70-can-i-sell-services#call"
                            target="_blank"
                            rel="noreferrer"
                          >
                            Learn more
                          </a>
                        </div>
                        <DurationsEditor
                          durations={productData.variants}
                          onChange={(variants) => form.setData("variants", variants)}
                          currencyType={currencyType}
                        />
                      </section>
                      <section className="p-4! md:p-8!">
                        <h2>Available hours</h2>
                        <AvailabilityEditor
                          availabilities={form.data.availabilities}
                          onChange={(availabilities) => form.setData("availabilities", availabilities)}
                        />
                      </section>
                      {form.data.call_limitation_info ? (
                        <section className="p-4! md:p-8!">
                          <h2>Call limitations</h2>
                          <CallLimitationsEditor
                            callLimitations={form.data.call_limitation_info}
                            onChange={(call_limitation_info) =>
                              form.setData("call_limitation_info", call_limitation_info)
                            }
                          />
                        </section>
                      ) : null}
                    </>
                  ) : (
                    <section aria-label="Version editor" className="p-4! md:p-8!">
                      <div style={{ display: "flex", justifyContent: "space-between" }}>
                        <h2>{productData.native_type === "physical" ? "Variants" : "Versions"}</h2>
                        <a
                          href="/help/article/126-setting-up-versions-on-a-digital-product"
                          target="_blank"
                          rel="noreferrer"
                        >
                          Learn more
                        </a>
                      </div>
                      <VersionsEditor
                        integrations={productData.integrations}
                        versions={productData.variants}
                        onChange={(variants) => form.setData("variants", variants)}
                        currencyType={currencyType}
                      />
                    </section>
                  )}
                </>
              )}
              {props.is_physical ? (
                <ShippingDestinationsEditor
                  shippingDestinations={form.data.shipping_destinations}
                  onChange={(shipping_destinations) => form.setData("shipping_destinations", shipping_destinations)}
                  availableCountries={[]}
                  currencyType={currencyType}
                />
              ) : null}
              <section className="p-4! md:p-8!">
                <h2>Settings</h2>
                <fieldset>
                  {productData.native_type === "membership" ? (
                    <>
                      <FreeTrialSelector product={form.data} updateProduct={updateProductPartial} />
                      {props.cancellation_discounts_enabled ? (
                        <CancellationDiscountSelector
                          product={form.data}
                          updateProduct={updateProductPartial}
                          currencyType={currencyType}
                        />
                      ) : null}
                      <Switch
                        checked={form.data.should_include_last_post}
                        onChange={(should_include_last_post) =>
                          form.setData("should_include_last_post", !should_include_last_post)
                        }
                        label="New members will be emailed this product's last published post"
                      />
                      <Switch
                        checked={form.data.should_show_all_posts}
                        onChange={(should_show_all_posts) =>
                          form.setData("should_show_all_posts", !should_show_all_posts)
                        }
                        label="New members will get access to all posts you have published"
                      />
                      <Switch
                        checked={form.data.block_access_after_membership_cancellation}
                        onChange={(block_access_after_membership_cancellation) =>
                          form.setData(
                            "block_access_after_membership_cancellation",
                            !block_access_after_membership_cancellation,
                          )
                        }
                        label="Members will lose access when their memberships end"
                      />
                      <DurationEditor product={form.data} updateProduct={updateProductPartial} />
                    </>
                  ) : null}
                  {form.data.can_enable_quantity ? (
                    <>
                      <MaxPurchaseCountToggle
                        maxPurchaseCount={form.data.max_purchase_count}
                        setMaxPurchaseCount={(count) => form.setData("max_purchase_count", count)}
                      />
                      <Switch
                        checked={form.data.quantity_enabled}
                        onChange={(quantity_enabled) => form.setData("quantity_enabled", !quantity_enabled)}
                        label="Allow customers to choose a quantity"
                      />
                    </>
                  ) : null}
                  {form.data.variants.length > 0 ? (
                    <Switch
                      checked={form.data.hide_sold_out_variants}
                      onChange={(hide_sold_out_variants) =>
                        form.setData("hide_sold_out_variants", !hide_sold_out_variants)
                      }
                      label="Hide sold out versions"
                    />
                  ) : null}
                  <Switch
                    checked={form.data.should_show_sales_count}
                    onChange={(should_show_sales_count) =>
                      form.setData("should_show_sales_count", !should_show_sales_count)
                    }
                    label={
                      productData.native_type === "membership"
                        ? "Publicly show the number of members on your product page"
                        : "Publicly show the number of sales on your product page"
                    }
                  />
                  <Switch
                    checked={form.data.is_epublication}
                    onChange={(is_epublication) => form.setData("is_epublication", !is_epublication)}
                    label={
                      <>
                        Mark product as e-publication for VAT purposes{" "}
                        <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                          Learn more
                        </a>
                      </>
                    }
                  />
                  {!props.seller_refund_policy_enabled ? (
                    <RefundPolicySelector
                      refundPolicy={form.data.refund_policy}
                      setRefundPolicy={(refund_policy) => form.setData("refund_policy", refund_policy)}
                      refundPolicies={props.refund_policies}
                      isEnabled={form.data.product_refund_policy_enabled}
                      setIsEnabled={(isEnabled) => form.setData("product_refund_policy_enabled", isEnabled)}
                      setShowPreview={() => setShowRefundPolicyPreview(true)}
                    />
                  ) : null}
                  <Switch
                    checked={form.data.require_shipping}
                    onChange={(require_shipping) => form.setData("require_shipping", !require_shipping)}
                    label="Require shipping information"
                  />
                </fieldset>
                {productData.native_type === "membership" ? (
                  <fieldset>
                    <legend>
                      <label htmlFor={`${uid}-subscription-duration`}>Default payment frequency</label>
                    </legend>
                    <TypeSafeOptionSelect
                      id={`${uid}-subscription-duration`}
                      value={form.data.subscription_duration || "monthly"}
                      onChange={(subscription_duration) => form.setData("subscription_duration", subscription_duration)}
                      options={recurrenceIds.map((recurrenceId) => ({
                        id: recurrenceId,
                        label: recurrenceLabels[recurrenceId],
                      }))}
                    />
                  </fieldset>
                ) : null}
                <CustomDomain
                  verificationStatus={props.custom_domain_verification_status}
                  customDomain={productData.custom_domain}
                  setCustomDomain={(custom_domain) => form.setData("custom_domain", custom_domain)}
                  label="Custom domain"
                  productId={props.id}
                  includeLearnMoreLink
                />
              </section>
            </>
          )}
        </form>
      </div>
    </Layout>
  );
}
