import * as React from "react";

import { recurrenceIds } from "$app/utils/recurringPricing";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Product, ProductDiscount } from "$app/components/Product";
import { CoffeeProduct } from "$app/components/Product/CoffeeProduct";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { RefundPolicyModalPreview } from "$app/components/ProductEdit/RefundPolicy";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

export const ProductPreview = ({ showRefundPolicyModal }: { showRefundPolicyModal?: boolean }) => {
  const currentSeller = useCurrentSeller();
  const {
    product,
    id,
    uniquePermalink,
    currencyType,
    salesCountForInventory,
    successfulSalesCount,
    ratings,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = useProductEditContext();

  const url = useProductUrl();

  if (!currentSeller) return null;

  const defaultRecurrence =
    product.native_type === "membership" ? (product.subscription_duration ?? recurrenceIds[0]) : null;

  const defaultDiscountCode: ProductDiscount | null = React.useMemo(() => {
    if (!product.default_offer_code) return null;

    return {
      valid: true as const,
      code: product.default_offer_code.code,
      discount: product.default_offer_code.discount,
    };
  }, [product.default_offer_code]);

  const serializedProduct: Product = {
    id,
    name: product.name,
    seller: {
      id: currentSeller.id,
      name: currentSeller.name ?? "",
      avatar_url: currentSeller.avatarUrl,
      profile_url: Routes.root_url({ host: currentSeller.subdomain }),
    },
    collaborating_user: product.collaborating_user,
    covers: product.covers,
    main_cover_id: product.covers[0]?.id ?? null,
    quantity_remaining:
      product.max_purchase_count !== null ? Math.max(product.max_purchase_count - salesCountForInventory, 0) : null,
    currency_code: currencyType,
    long_url: url,
    duration_in_months: null,
    is_sales_limited: product.max_purchase_count !== null,
    price_cents: product.price_cents,
    pwyw: product.customizable_price ? { suggested_price_cents: product.suggested_price_cents } : null,
    installment_plan: product.installment_plan,
    ratings: product.display_product_reviews ? ratings : null,
    is_legacy_subscription: false,
    is_tiered_membership: false,
    is_recurring_billing: product.native_type === "membership",
    is_physical: false,
    custom_view_content_button_text: null,
    permalink: uniquePermalink,
    preorder: null,
    description_html: product.description,
    is_compliance_blocked: false,
    is_published: product.is_published,
    is_stream_only: false,
    streamable: product.files.some((file) => file.is_streamable),
    is_quantity_enabled: product.quantity_enabled,
    is_multiseat_license: false,
    hide_sold_out_variants: product.hide_sold_out_variants,
    sales_count: product.should_show_sales_count ? successfulSalesCount : null,
    custom_button_text_option: product.custom_button_text_option,
    summary: product.custom_summary,
    attributes: product.custom_attributes,
    native_type: product.native_type,
    free_trial: product.free_trial_enabled
      ? {
          duration: {
            amount: product.free_trial_duration_amount ?? 1,
            unit: product.free_trial_duration_unit ?? "week",
          },
        }
      : null,
    rental: null,
    recurrences:
      defaultRecurrence && product.variants[0] && "recurrence_price_values" in product.variants[0]
        ? {
            default: defaultRecurrence,
            enabled: Object.entries(product.variants[0].recurrence_price_values).flatMap(([recurrence, value], idx) =>
              value.enabled
                ? {
                    recurrence,
                    price_cents: value.price_cents ?? 0,
                    id: idx.toString(),
                  }
                : [],
            ),
          }
        : null,
    options: product.variants.map((variant) => ({
      ...variant,
      price_difference_cents: "price_difference_cents" in variant ? variant.price_difference_cents : 0,
      is_pwyw: "customizable_price" in variant ? variant.customizable_price : product.customizable_price,
      quantity_left:
        variant.max_purchase_count !== null
          ? variant.max_purchase_count - (variant.sales_count_for_inventory ?? 0)
          : null,
      recurrence_price_values:
        "recurrence_price_values" in variant
          ? Object.fromEntries(
              Object.entries(variant.recurrence_price_values).flatMap(([recurrence, value]) =>
                value.enabled ? [[recurrence, { ...value, price_cents: value.price_cents ?? 0 }]] : [],
              ),
            )
          : null,
      duration_in_minutes: "duration_in_minutes" in variant ? variant.duration_in_minutes : null,
    })),
    analytics: {
      google_analytics_id: null,
      facebook_pixel_id: null,
      free_sales: false,
    },
    has_third_party_analytics: false,
    ppp_details: null,
    can_edit: false,
    refund_policy: seller_refund_policy_enabled
      ? {
          title: seller_refund_policy.title,
          fine_print: seller_refund_policy.fine_print ?? "",
          updated_at: "",
        }
      : {
          title:
            product.refund_policy.allowed_refund_periods_in_days.find(
              ({ key }) => key === product.refund_policy.max_refund_period_in_days,
            )?.value ?? "",
          fine_print: product.refund_policy.fine_print ?? "",
          updated_at: "",
        },
    bundle_products: [],
    public_files: product.public_files,
    audio_previews_enabled: product.audio_previews_enabled,
  };

  return product.native_type === "coffee" ? (
    <ProfileLayout
      creatorProfile={{
        external_id: currentSeller.id,
        avatar_url: currentSeller.avatarUrl,
        name: currentSeller.name ?? "",
        subdomain: currentSeller.subdomain,
        twitter_handle: "",
      }}
      hideFollowForm
    >
      <CoffeeProduct
        product={{
          ...serializedProduct,
          is_published: true,
          pwyw: {
            suggested_price_cents: Math.max(
              ...serializedProduct.options.map(({ price_difference_cents }) => price_difference_cents ?? 0),
            ),
          },
          options: serializedProduct.options.sort(
            (a, b) => (a.price_difference_cents ?? 0) - (b.price_difference_cents ?? 0),
          ),
        }}
        purchase={null}
        selection={{
          optionId: null,
          price: {
            value:
              serializedProduct.options.length === 1
                ? (serializedProduct.options[0]?.price_difference_cents ?? null)
                : null,
            error: false,
          },
        }}
      />
    </ProfileLayout>
  ) : (
    <>
      <RefundPolicyModalPreview open={showRefundPolicyModal ?? false} refundPolicy={product.refund_policy} />
      <Product
        product={serializedProduct}
        purchase={null}
        discountCode={defaultDiscountCode}
        selection={{
          quantity: 1,
          optionId: serializedProduct.options[0]?.id ?? null,
          recurrence: defaultRecurrence,
          price: { value: null, error: false },
          rent: false,
          callStartTime: null,
          payInInstallments: false,
        }}
        disableAnalytics
      />
    </>
  );
};
