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
import { Alert } from "$app/components/ui/Alert";

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
              <Alert role="status" variant="accent">
                <div className="flex items-center gap-4">
                  <Icon className="text-lg" name="sparkle" />
                  <div className="flex-1">
                    <strong>Sản phẩm AI của bạn đã sẵn sàng!</strong> Hãy dành chút thời gian xem qua tab sản phẩm và nội dung.
                    Chỉnh sửa và biến nó thành của riêng bạn—đây là lúc để bạn tỏa sáng!
                  </div>
                  <button
                    className="cursor-pointer self-center underline all-unset"
                    onClick={() => setShowAiNotification(false)}
                  >
                    đóng
                  </button>
                </div>
              </Alert>
            ) : null}
            <BundleConversionNotice />
            <fieldset>
              <label htmlFor={`${uid}-name`}>{isCoffee ? "Tiêu đề" : "Tên sản phẩm"}</label>
              <input
                id={`${uid}-name`}
                type="text"
                value={product.name}
                onChange={(evt) => updateProduct({ name: evt.target.value })}
                placeholder={isCoffee ? "Nhập tiêu đề" : "Nhập tên sản phẩm"}
              />
            </fieldset>
            {isCoffee ? (
              <>
                <fieldset>
                  <label htmlFor={`${uid}-body`}>Nội dung</label>
                  <textarea
                    id={`${uid}-body`}
                    value={product.description}
                    placeholder="Thêm một thông điệp truyền cảm hứng ngắn gọn"
                    onChange={(evt) => updateProduct({ description: evt.target.value })}
                  />
                </fieldset>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-url`}>URL</label>
                    <CopyToClipboard text={url}>
                      <button type="button" className="cursor-pointer font-normal underline all-unset">
                        Sao chép URL
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
                <h2>Giá</h2>
                <SuggestedAmountsEditor
                  versions={product.variants}
                  onChange={(variants) => updateProduct({ variants })}
                />
              </section>
              <section className="p-4! md:p-8!">
                <h2>Cài đặt</h2>
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
                <h2>Thông tin sản phẩm</h2>
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
                <h2>Tích hợp</h2>
                <fieldset>
                  {product.community_chat_enabled === null ? null : (
                    <ToggleSettingRow
                      label="Mời khách hàng tham gia cộng đồng chat Gumroad của bạn"
                      value={product.community_chat_enabled}
                      onChange={(newValue) => updateProduct({ community_chat_enabled: newValue })}
                      help={{
                        label: "Tìm hiểu thêm",
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
                  <h2>Cấp bậc</h2>
                  <TiersEditor tiers={product.variants} onChange={(variants) => updateProduct({ variants })} />
                </section>
              ) : (
                <>
                  <section className="p-4! md:p-8!">
                    <h2>Giá</h2>
                    <PriceEditor
                      priceCents={product.price_cents}
                      suggestedPriceCents={product.suggested_price_cents}
                      isPWYW={product.customizable_price}
                      setPriceCents={(priceCents) =>
                        updateProduct({
                          price_cents: priceCents,
                          ...(priceCents === 0 && { customizable_price: true }),
                        })
                      }
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
                        Sản phẩm hoa hồng sử dụng cách chia thanh toán 50% đặt cọc trước, 50% khi hoàn thành.
                      </p>
                    ) : null}
                  </section>
                  {product.native_type === "call" ? (
                    <>
                      <section className="p-4! md:p-8!">
                        <div style={{ display: "flex", justifyContent: "space-between" }}>
                          <h2>Thời lượng</h2>
                          <a
                            href="https://gumroad.com/help/article/70-can-i-sell-services#call"
                            target="_blank"
                            rel="noreferrer"
                          >
                            Tìm hiểu thêm
                          </a>
                        </div>
                        <DurationsEditor
                          durations={product.variants}
                          onChange={(variants) => updateProduct({ variants })}
                        />
                      </section>
                      <section className="p-4! md:p-8!">
                        <h2>Giờ làm việc</h2>
                        <AvailabilityEditor
                          availabilities={product.availabilities}
                          onChange={(availabilities) => updateProduct({ availabilities })}
                        />
                      </section>
                      {product.call_limitation_info ? (
                        <section className="p-4! md:p-8!">
                          <h2>Giới hạn cuộc gọi</h2>
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
                        <h2>{product.native_type === "physical" ? "Biến thể" : "Phiên bản"}</h2>
                        <a
                          href="/help/article/126-setting-up-versions-on-a-digital-product"
                          target="_blank"
                          rel="noreferrer"
                        >
                          Tìm hiểu thêm
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
                <h2>Cài đặt</h2>
                <fieldset>
                  {product.native_type === "membership" ? (
                    <>
                      <FreeTrialSelector />
                      {cancellationDiscountsEnabled ? <CancellationDiscountSelector /> : null}
                      <Toggle
                        value={product.should_include_last_post}
                        onChange={(should_include_last_post) => updateProduct({ should_include_last_post })}
                      >
                        Thành viên mới sẽ được gửi email bài viết đã xuất bản gần nhất của sản phẩm này
                      </Toggle>
                      <Toggle
                        value={product.should_show_all_posts}
                        onChange={(should_show_all_posts) => updateProduct({ should_show_all_posts })}
                      >
                        Thành viên mới sẽ được truy cập tất cả bài viết bạn đã xuất bản
                      </Toggle>
                      <Toggle
                        value={product.block_access_after_membership_cancellation}
                        onChange={(block_access_after_membership_cancellation) =>
                          updateProduct({ block_access_after_membership_cancellation })
                        }
                      >
                        Thành viên sẽ mất quyền truy cập khi tư cách thành viên kết thúc
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
                        Cho phép khách hàng chọn số lượng
                      </Toggle>
                    </>
                  ) : null}
                  {product.variants.length > 0 ? (
                    <Toggle
                      value={product.hide_sold_out_variants}
                      onChange={(newValue) => updateProduct({ hide_sold_out_variants: newValue })}
                    >
                      Ẩn các phiên bản đã hết hàng
                    </Toggle>
                  ) : null}
                  <Toggle
                    value={product.should_show_sales_count}
                    onChange={(newValue) => updateProduct({ should_show_sales_count: newValue })}
                  >
                    {product.native_type === "membership"
                      ? "Hiển thị công khai số lượng thành viên trên trang sản phẩm"
                      : "Hiển thị công khai số lượng đã bán trên trang sản phẩm"}
                  </Toggle>
                  {product.native_type !== "physical" ? (
                    <Toggle
                      value={product.is_epublication}
                      onChange={(newValue) => updateProduct({ is_epublication: newValue })}
                    >
                      Đánh dấu sản phẩm là ấn phẩm điện tử cho mục đích VAT{" "}
                      <a href="/help/article/10-dealing-with-vat" target="_blank" rel="noreferrer">
                        Tìm hiểu thêm
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
                    Yêu cầu thông tin giao hàng
                  </Toggle>
                </fieldset>
                {product.native_type === "membership" ? (
                  <fieldset>
                    <legend>
                      <label htmlFor={`${uid}-subscription-duration`}>Tần suất thanh toán mặc định</label>
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
                  label="Tên miền tùy chỉnh"
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
