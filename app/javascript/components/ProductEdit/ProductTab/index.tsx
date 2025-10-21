import * as React from "react";

import { COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS, CUSTOM_BUTTON_TEXT_OPTIONS } from "$app/parsers/product";
import { currencyCodeList } from "$app/utils/currency";
import { recurrenceLabels, recurrenceIds } from "$app/utils/recurringPricing";

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
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Toggle } from "$app/components/Toggle";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

export const ProductTab = () => {
  const uid = React.useId();
  const currentSeller = useCurrentSeller();

  const {
    id,
    product,
    updateProduct,
    uniquePermalink,
    thumbnail: initialThumbnail,
    refundPolicies,
    currencyType,
    setCurrencyType,
    isPhysical,
    customDomainVerificationStatus,
    googleCalendarEnabled,
    seller_refund_policy_enabled,
    cancellationDiscountsEnabled,
  } = useProductEditContext();
  const [initialProduct] = React.useState(product);

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail);
  const [showAiNotification, setShowAiNotification] = React.useState(false);

  React.useEffect(() => {
    if (window.location.hash === "#ai-generated") {
      setShowAiNotification(true);
      window.history.replaceState(null, "", window.location.pathname + window.location.search);
    }
  }, []);

  const { isUploading, setImagesUploading } = useImageUpload();

  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  const isCoffee = product.native_type === "coffee";

  const url = useProductUrl();

  if (!currentSeller) return null;

  return (
    <Layout preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />} isLoading={isUploading}>
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            {showAiNotification ? (
              <div
                role="status"
                className="grid grid-cols-[auto_1fr_auto] items-start gap-4 rounded-lg !border-pink bg-pink/20 p-6"
              >
                <span className="self-center text-lg">
                  <Icon name="sparkle" />
                </span>
                <div>
                  <strong>Your AI product is ready!</strong> Take a moment to check out the product and content tabs.
                  Tweak things and make it your own—this is your time to shine!
                </div>
                <button className="col-start-3! self-center underline" onClick={() => setShowAiNotification(false)}>
                  close
                </button>
              </div>
            ) : null}
            <BundleConversionNotice />
            <fieldset>
              <label htmlFor={`${uid}-name`}>{isCoffee ? "Header" : "Name"}</label>
              <input
                id={`${uid}-name`}
                type="text"
                value={product.name}
                onChange={(evt) => updateProduct({ name: evt.target.value })}
              />
            </fieldset>
            {isCoffee ? (
              <>
                <fieldset>
                  <label htmlFor={`${uid}-body`}>Body</label>
                  <textarea
                    id={`${uid}-body`}
                    value={product.description}
                    placeholder="Add a short inspiring message"
                    onChange={(evt) => updateProduct({ description: evt.target.value })}
                  />
                </fieldset>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-url`}>URL</label>
                    <CopyToClipboard text={url}>
                      <button type="button" className="font-normal underline">
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
                  id={id}
                  initialDescription={initialProduct.description}
                  onChange={(description) => updateProduct({ description })}
                  setImagesUploading={setImagesUploading}
                  publicFiles={product.public_files}
                  updatePublicFiles={(updater) => updateProduct((product) => updater(product.public_files))}
                  audioPreviewsEnabled={product.audio_previews_enabled}
                />
                <CustomPermalinkInput
                  value={product.custom_permalink}
                  onChange={(value) => updateProduct({ custom_permalink: value })}
                  uniquePermalink={uniquePermalink}
                  url={url}
                />
              </>
            )}
          </section>
          {isCoffee ? (
            <>
              <section className="p-4! md:p-8!">
                <h2>Pricing</h2>
                <SuggestedAmountsEditor
                  versions={product.variants}
                  onChange={(variants) => updateProduct({ variants })}
                />
              </section>
              <section className="p-4! md:p-8!">
                <h2>Settings</h2>
                <CustomButtonTextOptionInput
                  value={product.custom_button_text_option}
                  onChange={(value) => updateProduct({ custom_button_text_option: value })}
                  options={COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS}
                />
              </section>
            </>
          ) : (
            <>
              <CoverEditor
                covers={product.covers}
                setCovers={(covers) => updateProduct({ covers })}
                permalink={uniquePermalink}
              />
              <ThumbnailEditor
                covers={product.covers}
                thumbnail={thumbnail}
                setThumbnail={setThumbnail}
                permalink={uniquePermalink}
                nativeType={product.native_type}
              />
              <section className="p-4! md:p-8!">
                <h2>Product info</h2>
                {product.native_type !== "membership" ? (
                  <CustomButtonTextOptionInput
                    value={product.custom_button_text_option}
                    onChange={(value) => updateProduct({ custom_button_text_option: value })}
                    options={CUSTOM_BUTTON_TEXT_OPTIONS}
                  />
                ) : null}
                <CustomSummaryInput
                  value={product.custom_summary}
                  onChange={(value) => updateProduct({ custom_summary: value })}
                />
                <AttributesEditor
                  customAttributes={product.custom_attributes}
                  setCustomAttributes={(custom_attributes) => updateProduct({ custom_attributes })}
                  fileAttributes={product.file_attributes}
                  setFileAttributes={(file_attributes) => updateProduct({ file_attributes })}
                />
              </section>
              <section className="p-4! md:p-8!">
                <h2>Integrations</h2>
                <fieldset>
                  {product.community_chat_enabled === null ? null : (
                    <ToggleSettingRow
                      label="Invite your customers to your Gumroad community chat"
                      value={product.community_chat_enabled}
                      onChange={(newValue) => updateProduct({ community_chat_enabled: newValue })}
                      help={{
                        label: "Learn more",
                        url: "/help/article/347-gumroad-community",
                      }}
                    />
                  )}
                  <CircleIntegrationEditor
                    integration={product.integrations.circle}
                    onChange={(newIntegration) =>
                      updateProduct({
                        integrations: {
                          ...product.integrations,
                          circle: newIntegration,
                        },
                      })
                    }
                  />
                  <DiscordIntegrationEditor
                    integration={product.integrations.discord}
                    onChange={(newIntegration) =>
                      updateProduct({
                        integrations: {
                          ...product.integrations,
                          discord: newIntegration,
                        },
                      })
                    }
                  />
                  {product.native_type === "call" && googleCalendarEnabled ? (
                    <GoogleCalendarIntegrationEditor
                      integration={product.integrations.google_calendar}
                      onChange={(newIntegration) =>
                        updateProduct({
                          integrations: {
                            ...product.integrations,
                            google_calendar: newIntegration,
                          },
                        })
                      }
                    />
                  ) : null}
                </fieldset>
              </section>
              {product.native_type === "membership" ? (
                <section className="p-4! md:p-8!">
                  <h2>Tiers</h2>
                  <TiersEditor tiers={product.variants} onChange={(variants) => updateProduct({ variants })} />
                </section>
              ) : (
                <>
                  <section className="p-4! md:p-8!">
                    <h2>Pricing</h2>
                    <PriceEditor
                      priceCents={product.price_cents}
                      suggestedPriceCents={product.suggested_price_cents}
                      isPWYW={product.customizable_price}
                      setPriceCents={(priceCents) => updateProduct({ price_cents: priceCents })}
                      setSuggestedPriceCents={(suggestedPriceCents) =>
                        updateProduct({ suggested_price_cents: suggestedPriceCents })
                      }
                      currencyCodeSelector={{
                        options: currencyCodeList,
                        onChange: (currencyCode) => {
                          setCurrencyType(currencyCode);
                        },
                      }}
                      setIsPWYW={(isPWYW) => updateProduct({ customizable_price: isPWYW })}
                      currencyType={currencyType}
                      eligibleForInstallmentPlans={product.eligible_for_installment_plans}
                      allowInstallmentPlan={product.allow_installment_plan}
                      numberOfInstallments={product.installment_plan?.number_of_installments ?? null}
                      onAllowInstallmentPlanChange={(allowed) => updateProduct({ allow_installment_plan: allowed })}
                      onNumberOfInstallmentsChange={(value) =>
                        updateProduct({
                          installment_plan: { ...product.installment_plan, number_of_installments: value },
                        })
                      }
                    />
                    {product.native_type === "commission" ? (
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
                  {product.native_type === "call" ? (
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
                          durations={product.variants}
                          onChange={(variants) => updateProduct({ variants })}
                        />
                      </section>
                      <section className="p-4! md:p-8!">
                        <h2>Available hours</h2>
                        <AvailabilityEditor
                          availabilities={product.availabilities}
                          onChange={(availabilities) => updateProduct({ availabilities })}
                        />
                      </section>
                      {product.call_limitation_info ? (
                        <section className="p-4! md:p-8!">
                          <h2>Call limitations</h2>
                          <CallLimitationsEditor
                            callLimitations={product.call_limitation_info}
                            onChange={(call_limitation_info) => updateProduct({ call_limitation_info })}
                          />
                        </section>
                      ) : null}
                    </>
                  ) : (
                    <section aria-label="Version editor" className="p-4! md:p-8!">
                      <div style={{ display: "flex", justifyContent: "space-between" }}>
                        <h2>{product.native_type === "physical" ? "Variants" : "Versions"}</h2>
                        <a
                          href="/help/article/126-setting-up-versions-on-a-digital-product"
                          target="_blank"
                          rel="noreferrer"
                        >
                          Learn more
                        </a>
                      </div>
                      <VersionsEditor
                        versions={product.variants}
                        onChange={(variants) => updateProduct({ variants })}
                      />
                    </section>
                  )}
                </>
              )}
              {isPhysical ? (
                <ShippingDestinationsEditor
                  shippingDestinations={product.shipping_destinations}
                  onChange={(shipping_destinations) => updateProduct({ shipping_destinations })}
                />
              ) : null}
              <section className="p-4! md:p-8!">
                <h2>Settings</h2>
                <fieldset>
                  {product.native_type === "membership" ? (
                    <>
                      <FreeTrialSelector />
                      {cancellationDiscountsEnabled ? <CancellationDiscountSelector /> : null}
                      <Toggle
                        value={product.should_include_last_post}
                        onChange={(should_include_last_post) => updateProduct({ should_include_last_post })}
                      >
                        New members will be emailed this product's last published post
                      </Toggle>
                      <Toggle
                        value={product.should_show_all_posts}
                        onChange={(should_show_all_posts) => updateProduct({ should_show_all_posts })}
                      >
                        New members will get access to all posts you have published
                      </Toggle>
                      <Toggle
                        value={product.block_access_after_membership_cancellation}
                        onChange={(block_access_after_membership_cancellation) =>
                          updateProduct({ block_access_after_membership_cancellation })
                        }
                      >
                        Members will lose access when their memberships end
                      </Toggle>
                      <DurationEditor />
                    </>
                  ) : null}
                  {product.can_enable_quantity ? (
                    <>
                      <MaxPurchaseCountToggle
                        maxPurchaseCount={product.max_purchase_count}
                        setMaxPurchaseCount={(value) => updateProduct({ max_purchase_count: value })}
                      />
                      <Toggle
                        value={product.quantity_enabled}
                        onChange={(newValue) => updateProduct({ quantity_enabled: newValue })}
                      >
                        Allow customers to choose a quantity
                      </Toggle>
                    </>
                  ) : null}
                  {product.variants.length > 0 ? (
                    <Toggle
                      value={product.hide_sold_out_variants}
                      onChange={(newValue) => updateProduct({ hide_sold_out_variants: newValue })}
                    >
                      Hide sold out versions
                    </Toggle>
                  ) : null}
                  <Toggle
                    value={product.should_show_sales_count}
                    onChange={(newValue) => updateProduct({ should_show_sales_count: newValue })}
                  >
                    {product.native_type === "membership"
                      ? "Publicly show the number of members on your product page"
                      : "Publicly show the number of sales on your product page"}
                  </Toggle>
                  {product.native_type !== "physical" ? (
                    <Toggle
                      value={product.is_epublication}
                      onChange={(newValue) => updateProduct({ is_epublication: newValue })}
                    >
                      Mark product as e-publication for VAT purposes{" "}
                      <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                        Learn more
                      </a>
                    </Toggle>
                  ) : null}
                  {!seller_refund_policy_enabled ? (
                    <RefundPolicySelector
                      refundPolicy={product.refund_policy}
                      setRefundPolicy={(newValue) => updateProduct({ refund_policy: newValue })}
                      refundPolicies={refundPolicies}
                      isEnabled={product.product_refund_policy_enabled}
                      setIsEnabled={(newValue) => updateProduct({ product_refund_policy_enabled: newValue })}
                      setShowPreview={setShowRefundPolicyPreview}
                    />
                  ) : null}
                  <Toggle
                    value={product.require_shipping}
                    onChange={(newValue) => updateProduct({ require_shipping: newValue })}
                  >
                    Require shipping information
                  </Toggle>
                </fieldset>
                {product.native_type === "membership" ? (
                  <fieldset>
                    <legend>
                      <label htmlFor={`${uid}-subscription-duration`}>Default payment frequency</label>
                    </legend>
                    <TypeSafeOptionSelect
                      id={`${uid}-subscription-duration`}
                      value={product.subscription_duration || "monthly"}
                      onChange={(subscription_duration) => updateProduct({ subscription_duration })}
                      options={recurrenceIds.map((recurrenceId) => ({
                        id: recurrenceId,
                        label: recurrenceLabels[recurrenceId],
                      }))}
                    />
                  </fieldset>
                ) : null}
                <CustomDomain
                  verificationStatus={customDomainVerificationStatus}
                  customDomain={product.custom_domain}
                  setCustomDomain={(custom_domain) => updateProduct({ custom_domain })}
                  label="Custom domain"
                  productId={id}
                  includeLearnMoreLink
                />
              </section>
            </>
          )}
        </form>
      </div>
    </Layout>
  );
};
