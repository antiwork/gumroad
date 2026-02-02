import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import {
  AssetPreview,
  COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS,
  CUSTOM_BUTTON_TEXT_OPTIONS,
  CustomButtonTextOption,
} from "$app/parsers/product";
import { CurrencyCode, currencyCodeList } from "$app/utils/currency";
import { recurrenceIds, recurrenceLabels } from "$app/utils/recurringPricing";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import CustomDomain from "$app/components/CustomDomain";
import { Icon } from "$app/components/Icons";
import { Seller } from "$app/components/Product";
import { Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

import {
  Availability,
  BaseProductEditPageProps,
  CallLimitationInfo,
  Duration,
  InstallmentPlan,
  PublicFileWithStatus,
  ShippingDestination,
  Tier,
  Version,
} from "../Shared/types";
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
import { Switch } from "$app/components/ui/Switch";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { EditLayout } from "../Shared/EditLayout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";

type ProductPageProps = BaseProductEditPageProps & {
  product: {
    name: string;
    description: string;
    native_type: string;
    custom_permalink: string | null;
    covers: AssetPreview[];
    collaborating_user: Seller | null;
    customizable_price: boolean;
    price_cents: number;
    suggested_price_cents: number | null;
    eligible_for_installment_plans: boolean;
    allow_installment_plan: boolean;
    installment_plan: InstallmentPlan | null;
    max_purchase_count: number | null;
    quantity_enabled: boolean;
    should_show_sales_count: boolean;
    is_epublication: boolean;
    product_refund_policy_enabled: boolean;
    custom_button_text_option: CustomButtonTextOption | null;
    custom_summary: string | null;
    custom_attributes: Attribute[];
    file_attributes: Attribute[];
    refund_policy: RefundPolicy;
    display_product_reviews: boolean;
    public_files: PublicFileWithStatus[];
    audio_previews_enabled: boolean;
    is_published: boolean;
    community_chat_enabled: boolean | null;
    integrations: {
      discord: { enabled: boolean; role_id: string | null };
      circle: { enabled: boolean; community_id: string | null; space_id: string | null };
      google_calendar: { enabled: boolean };
    };
    variants: Version[] | Duration[] | Tier[];
    shipping_destinations: ShippingDestination[];
    can_enable_quantity: boolean;
    hide_sold_out_variants: boolean;
    require_shipping: boolean;
    subscription_duration: string | null;
    should_include_last_post: boolean;
    should_show_all_posts: boolean;
    block_access_after_membership_cancellation: boolean;
    availabilities: Availability[];
    call_limitation_info: CallLimitationInfo | null;
    custom_domain: string | null;
  };
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  currency_type: CurrencyCode;
  is_physical: boolean;
  custom_domain_verification_status: string;
  google_calendar_enabled: boolean;
  seller_refund_policy_enabled: boolean;
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
  file_attributes: Attribute[];
  covers: AssetPreview[];
  refund_policy: RefundPolicy;
  allow_installment_plan: boolean;
  installment_plan: InstallmentPlan | null;
  community_chat_enabled: boolean | null;
  integrations: {
    discord: { enabled: boolean; role_id: string | null };
    circle: { enabled: boolean; community_id: string | null; space_id: string | null };
    google_calendar: { enabled: boolean };
  };
  variants: Version[] | Duration[] | Tier[];
  shipping_destinations: ShippingDestination[];
  hide_sold_out_variants: boolean;
  require_shipping: boolean;
  subscription_duration: string | null;
  should_include_last_post: boolean;
  should_show_all_posts: boolean;
  block_access_after_membership_cancellation: boolean;
  availabilities: Availability[];
  call_limitation_info: CallLimitationInfo | null;
  custom_domain: string | null;
  files: any[];
  display_product_reviews: boolean;
  collaborating_user: Seller | null;
  native_type: string;
  price_currency_type?: CurrencyCode;
  unpublish?: boolean;
  redirect_to?: string;
};

export default function ProductsProductEdit() {
  const page = usePage<ProductPageProps>();
  const props = page.props;
  const {
    product: initialProduct,
    id,
    unique_permalink,
    currency_type,
    thumbnail: initialThumbnail,
    refund_policies,
    is_physical,
    custom_domain_verification_status,
    google_calendar_enabled,
    seller_refund_policy_enabled,
    cancellation_discounts_enabled,
    ai_generated,
  } = props;

  const uid = React.useId();
  const currentSeller = useCurrentSeller();

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail ?? null);
  const [showAiNotification, setShowAiNotification] = React.useState(ai_generated);
  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);
  const [currencyType, setCurrencyType] = React.useState(currency_type);
  const [publicFiles, setPublicFiles] = React.useState(initialProduct.public_files);

  const { setImagesUploading } = useImageUpload();

  const updatePublicFiles = React.useCallback((updater: (prev: typeof publicFiles) => void) => {
    setPublicFiles((prev) => {
      const next = [...prev];
      updater(next);
      return next;
    });
  }, []);

  const form = useForm<ProductFormData>({
    name: initialProduct.name,
    description: initialProduct.description,
    custom_permalink: initialProduct.custom_permalink,
    price_cents: initialProduct.price_cents,
    customizable_price: initialProduct.customizable_price,
    suggested_price_cents: initialProduct.suggested_price_cents,
    max_purchase_count: initialProduct.max_purchase_count,
    quantity_enabled: initialProduct.quantity_enabled,
    should_show_sales_count: initialProduct.should_show_sales_count,
    is_epublication: initialProduct.is_epublication,
    product_refund_policy_enabled: initialProduct.product_refund_policy_enabled,
    custom_button_text_option: initialProduct.custom_button_text_option,
    custom_summary: initialProduct.custom_summary,
    custom_attributes: initialProduct.custom_attributes,
    file_attributes: initialProduct.file_attributes,
    covers: initialProduct.covers,
    refund_policy: initialProduct.refund_policy,
    allow_installment_plan: initialProduct.allow_installment_plan,
    installment_plan: initialProduct.installment_plan,
    community_chat_enabled: initialProduct.community_chat_enabled,
    integrations: initialProduct.integrations,
    variants: initialProduct.variants,
    shipping_destinations: initialProduct.shipping_destinations,
    hide_sold_out_variants: initialProduct.hide_sold_out_variants,
    require_shipping: initialProduct.require_shipping,
    subscription_duration: initialProduct.subscription_duration,
    should_include_last_post: initialProduct.should_include_last_post,
    should_show_all_posts: initialProduct.should_show_all_posts,
    block_access_after_membership_cancellation: initialProduct.block_access_after_membership_cancellation,
    availabilities: initialProduct.availabilities,
    call_limitation_info: initialProduct.call_limitation_info,
    custom_domain: initialProduct.custom_domain,
    files: [],
    display_product_reviews: initialProduct.display_product_reviews,
    collaborating_user: initialProduct.collaborating_user,
    native_type: initialProduct.native_type,
  });

  if (!currentSeller) return null;

  const isCoffee = initialProduct.native_type === "coffee";

  const url = isCoffee
    ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain })
    : Routes.short_link_url(initialProduct.custom_permalink ?? unique_permalink, {
        host: currentSeller.subdomain,
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
    custom_button_text_option: form.data.custom_button_text_option,
    custom_summary: form.data.custom_summary,
    custom_attributes: form.data.custom_attributes,
    file_attributes: form.data.file_attributes,
    covers: form.data.covers.map(({ id }) => id),
    refund_policy: form.data.refund_policy,
    allow_installment_plan: form.data.allow_installment_plan,
    installment_plan: form.data.allow_installment_plan ? form.data.installment_plan : null,
    community_chat_enabled: form.data.community_chat_enabled,
    integrations: form.data.integrations,
    variants: form.data.variants.map((variant) => {
      const { newlyAdded, ...rest } = variant as any;
      return newlyAdded ? { ...rest, id: null } : rest;
    }),
    shipping_destinations: form.data.shipping_destinations,
    hide_sold_out_variants: form.data.hide_sold_out_variants,
    require_shipping: form.data.require_shipping,
    subscription_duration: form.data.subscription_duration,
    should_include_last_post: form.data.should_include_last_post,
    should_show_all_posts: form.data.should_show_all_posts,
    block_access_after_membership_cancellation: form.data.block_access_after_membership_cancellation,
    availabilities: form.data.availabilities.map((availability) => {
      const { newlyAdded, ...rest } = availability as any;
      return newlyAdded ? { ...rest, id: null } : rest;
    }),
    call_limitation_info: form.data.call_limitation_info,
    custom_domain: form.data.custom_domain,
    price_currency_type: currencyType,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}, options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformProductData(), ...additionalData }));
    form.put(Routes.product_product_path(id), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = async () => {
    submitForm();
  };

  // Build preview product from form data
  const previewProduct = {
    ...initialProduct,
    ...form.data,
    public_files: publicFiles,
  } as any;

  // Update product helper for components that need to update product state
  const updateProduct = (updater: any) => {
    const updates = typeof updater === "function" ? updater(form.data) : updater;
    form.setData((prev) => ({ ...prev, ...updates }));
  };

  // Create filesById map (dummy for now since we don't have files on this tab)
  const filesById = React.useMemo(() => new Map(), []);

  // Create the context value for components that use useProductEditContext
  const contextValue = React.useMemo(
    () => ({
      id,
      product: form.data as any,
      updateProduct,
      uniquePermalink: unique_permalink,
      seller: currentSeller as any,
      existingFiles: [],
      setExistingFiles: () => {},
      awsKey: "",
      s3Url: "",
      save: handleSave,
      saving: form.processing,
      filesById,
      thumbnail,
      refundPolicies: refund_policies,
      currencyType,
      setCurrencyType,
      isListedOnDiscover: false,
      isPhysical: is_physical,
      profileSections: [],
      taxonomies: [],
      earliestMembershipPriceChangeDate: new Date(),
      customDomainVerificationStatus: custom_domain_verification_status as any,
      salesCountForInventory: 0,
      successfulSalesCount: 0,
      ratings: {} as any,
      availableCountries: [],
      googleClientId: "",
      googleCalendarEnabled: google_calendar_enabled,
      seller_refund_policy_enabled,
      seller_refund_policy: { title: "", fine_print: "" },
      cancellationDiscountsEnabled: cancellation_discounts_enabled,
      contentUpdates: null,
      setContentUpdates: () => {},
      aiGenerated: ai_generated,
    }),
    [
      id,
      form.data,
      form.processing,
      unique_permalink,
      currentSeller,
      thumbnail,
      refund_policies,
      currencyType,
      is_physical,
      custom_domain_verification_status,
      google_calendar_enabled,
      seller_refund_policy_enabled,
      cancellation_discounts_enabled,
      ai_generated,
    ],
  );

  return (
    <ProductEditContext.Provider value={contextValue}>
      <EditLayout
        productId={id}
        uniquePermalink={unique_permalink}
        currentTab="product"
        onSave={handleSave}
        isSaving={form.processing}
        preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />}
        product={previewProduct}
      >
        <div className="squished">
        <form>
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
                    className="cursor-pointer self-center underline all-unset"
                    onClick={() => setShowAiNotification(false)}
                  >
                    close
                  </button>
                </div>
              </Alert>
            ) : null}
            <BundleConversionNotice />
            <fieldset>
              <label htmlFor={`${uid}-name`}>{isCoffee ? "Header" : "Name"}</label>
              <input
                id={`${uid}-name`}
                type="text"
                value={form.data.name}
                onChange={(evt) => form.setData("name", evt.target.value)}
              />
            </fieldset>
            {isCoffee ? (
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
                  id={id}
                  initialDescription={initialProduct.description}
                  onChange={(description) => form.setData("description", description)}
                  setImagesUploading={setImagesUploading}
                  publicFiles={publicFiles}
                  updatePublicFiles={updatePublicFiles}
                  audioPreviewsEnabled={initialProduct.audio_previews_enabled}
                />
                <CustomPermalinkInput
                  value={form.data.custom_permalink}
                  onChange={(value) => form.setData("custom_permalink", value)}
                  uniquePermalink={unique_permalink}
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
                  versions={form.data.variants as Version[]}
                  onChange={(variants) => form.setData("variants", variants)}
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
                permalink={unique_permalink}
              />
              <ThumbnailEditor
                covers={form.data.covers}
                thumbnail={thumbnail}
                setThumbnail={setThumbnail}
                permalink={unique_permalink}
                nativeType={initialProduct.native_type as any}
              />
              <section className="p-4! md:p-8!">
                <h2>Product info</h2>
                {initialProduct.native_type !== "membership" ? (
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
                    <Switch
                      checked={form.data.community_chat_enabled}
                      onChange={(e) => form.setData("community_chat_enabled", e.target.checked)}
                      label="Invite your customers to your Gumroad community chat"
                    />
                  )}
                  <CircleIntegrationEditor
                    integration={form.data.integrations.circle as any}
                    onChange={(newIntegration) =>
                      form.setData("integrations", {
                        ...form.data.integrations,
                        circle: newIntegration as any,
                      })
                    }
                  />
                  <DiscordIntegrationEditor
                    integration={form.data.integrations.discord as any}
                    onChange={(newIntegration) =>
                      form.setData("integrations", {
                        ...form.data.integrations,
                        discord: newIntegration as any,
                      })
                    }
                  />
                  {initialProduct.native_type === "call" && google_calendar_enabled ? (
                    <GoogleCalendarIntegrationEditor
                      integration={form.data.integrations.google_calendar as any}
                      onChange={(newIntegration) =>
                        form.setData("integrations", {
                          ...form.data.integrations,
                          google_calendar: newIntegration as any,
                        })
                      }
                    />
                  ) : null}
                </fieldset>
              </section>
              {initialProduct.native_type === "membership" ? (
                <section className="p-4! md:p-8!">
                  <h2>Tiers</h2>
                  <TiersEditor
                    tiers={form.data.variants as Tier[]}
                    onChange={(variants) => form.setData("variants", variants)}
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
                        form.setData({
                          ...form.data,
                          price_cents: priceCents,
                          ...(priceCents === 0 && { customizable_price: true }),
                        });
                      }}
                      setSuggestedPriceCents={(suggestedPriceCents) =>
                        form.setData("suggested_price_cents", suggestedPriceCents)
                      }
                      currencyCodeSelector={{
                        options: currencyCodeList,
                        onChange: (currencyCode) => {
                          setCurrencyType(currencyCode);
                        },
                      }}
                      setIsPWYW={(isPWYW) => form.setData("customizable_price", isPWYW)}
                      currencyType={currencyType}
                      eligibleForInstallmentPlans={initialProduct.eligible_for_installment_plans}
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
                    {initialProduct.native_type === "commission" ? (
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
                  {initialProduct.native_type === "call" ? (
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
                          durations={form.data.variants as Duration[]}
                          onChange={(variants) => form.setData("variants", variants)}
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
                            onChange={(call_limitation_info) => form.setData("call_limitation_info", call_limitation_info)}
                          />
                        </section>
                      ) : null}
                    </>
                  ) : (
                    <section aria-label="Version editor" className="p-4! md:p-8!">
                      <div style={{ display: "flex", justifyContent: "space-between" }}>
                        <h2>{initialProduct.native_type === "physical" ? "Variants" : "Versions"}</h2>
                        <a
                          href="/help/article/126-setting-up-versions-on-a-digital-product"
                          target="_blank"
                          rel="noreferrer"
                        >
                          Learn more
                        </a>
                      </div>
                      <VersionsEditor
                        versions={form.data.variants as Version[]}
                        onChange={(variants) => form.setData("variants", variants)}
                      />
                    </section>
                  )}
                </>
              )}
              {is_physical ? (
                <ShippingDestinationsEditor
                  shippingDestinations={form.data.shipping_destinations}
                  onChange={(shipping_destinations) => form.setData("shipping_destinations", shipping_destinations)}
                />
              ) : null}
              <section className="p-4! md:p-8!">
                <h2>Settings</h2>
                <fieldset>
                  {initialProduct.native_type === "membership" ? (
                    <>
                      <FreeTrialSelector />
                      {cancellation_discounts_enabled ? <CancellationDiscountSelector /> : null}
                      <Switch
                        checked={form.data.should_include_last_post}
                        onChange={(e) => form.setData("should_include_last_post", e.target.checked)}
                        label="New members will be emailed this product's last published post"
                      />
                      <Switch
                        checked={form.data.should_show_all_posts}
                        onChange={(e) => form.setData("should_show_all_posts", e.target.checked)}
                        label="New members will get access to all posts you have published"
                      />
                      <Switch
                        checked={form.data.block_access_after_membership_cancellation}
                        onChange={(e) =>
                          form.setData("block_access_after_membership_cancellation", e.target.checked)
                        }
                        label="Members will lose access when their memberships end"
                      />
                      <DurationEditor />
                    </>
                  ) : null}
                  {initialProduct.can_enable_quantity ? (
                    <>
                      <MaxPurchaseCountToggle
                        maxPurchaseCount={form.data.max_purchase_count}
                        setMaxPurchaseCount={(value) => form.setData("max_purchase_count", value)}
                      />
                      <Switch
                        checked={form.data.quantity_enabled}
                        onChange={(e) => form.setData("quantity_enabled", e.target.checked)}
                        label="Allow customers to choose a quantity"
                      />
                    </>
                  ) : null}
                  {form.data.variants.length > 0 ? (
                    <Switch
                      checked={form.data.hide_sold_out_variants}
                      onChange={(e) => form.setData("hide_sold_out_variants", e.target.checked)}
                      label="Hide sold out versions"
                    />
                  ) : null}
                  <Switch
                    checked={form.data.should_show_sales_count}
                    onChange={(e) => form.setData("should_show_sales_count", e.target.checked)}
                    label={
                      initialProduct.native_type === "membership"
                        ? "Publicly show the number of members on your product page"
                        : "Publicly show the number of sales on your product page"
                    }
                  />
                  {initialProduct.native_type !== "physical" ? (
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
                  ) : null}
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
                  <Switch
                    checked={form.data.require_shipping}
                    onChange={(e) => form.setData("require_shipping", e.target.checked)}
                    label="Require shipping information"
                  />
                </fieldset>
                {initialProduct.native_type === "membership" ? (
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
                  verificationStatus={custom_domain_verification_status as any}
                  customDomain={form.data.custom_domain ?? ""}
                  setCustomDomain={(custom_domain) => form.setData("custom_domain", custom_domain)}
                  label="Custom domain"
                  productId={id}
                  includeLearnMoreLink
                />
              </section>
            </>
          )}
        </form>
      </div>
      </EditLayout>
    </ProductEditContext.Provider>
  );
}
