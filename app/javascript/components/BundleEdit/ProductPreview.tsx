import * as React from "react";

import { useProductUrl } from "$app/components/BundleEdit/Layout";
import { computeStandalonePrice, useBundleEditContext } from "$app/components/BundleEdit/state";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Product } from "$app/components/Product";
import { RefundPolicyModalPreview } from "$app/components/ProductEdit/RefundPolicy";

export const ProductPreview = ({ showRefundPolicyModal }: { showRefundPolicyModal?: boolean }) => {
  const currentSeller = useCurrentSeller();
  const {
    bundle,
    id,
    uniquePermalink,
    currencyType,
    salesCountForInventory,
    ratings,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = useBundleEditContext();
  const url = useProductUrl();

  if (!currentSeller) return null;

  return (
    <>
      <RefundPolicyModalPreview open={showRefundPolicyModal ?? false} refundPolicy={bundle.refund_policy} />
      <Product
        product={{
          id,
          name: bundle.name,
          seller: {
            id: currentSeller.id,
            name: currentSeller.name ?? "",
            avatar_url: currentSeller.avatarUrl,
            profile_url: Routes.root_url({ host: currentSeller.subdomain }),
          },
          collaborating_user: bundle.collaborating_user,
          covers: bundle.covers,
          main_cover_id: bundle.covers[0]?.id ?? null,
          quantity_remaining:
            bundle.max_purchase_count !== null ? Math.max(bundle.max_purchase_count - salesCountForInventory, 0) : null,
          currency_code: currencyType,
          long_url: url,
          duration_in_months: null,
          is_sales_limited: bundle.max_purchase_count !== null,
          price_cents: bundle.price_cents,
          pwyw: bundle.customizable_price ? { suggested_price_cents: bundle.suggested_price_cents } : null,
          installment_plan: bundle.allow_installment_plan ? bundle.installment_plan : null,
          ratings: bundle.display_product_reviews ? ratings : null,
          is_legacy_subscription: false,
          is_tiered_membership: false,
          is_recurring_billing: false,
          is_physical: false,
          custom_view_content_button_text: null,
          permalink: uniquePermalink,
          preorder: null,
          description_html: bundle.description,
          is_compliance_blocked: false,
          is_published: bundle.is_published,
          is_stream_only: false,
          streamable: false,
          is_quantity_enabled: bundle.quantity_enabled,
          is_multiseat_license: false,
          hide_sold_out_variants: false,
          native_type: "bundle",
          sales_count: bundle.should_show_sales_count ? salesCountForInventory : null,
          custom_button_text_option: bundle.custom_button_text_option,
          summary: bundle.custom_summary,
          attributes: bundle.custom_attributes,
          free_trial: null,
          rental: null,
          recurrences: null,
          options: [],
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
                  bundle.refund_policy.allowed_refund_periods_in_days.find(
                    ({ key }) => key === bundle.refund_policy.max_refund_period_in_days,
                  )?.value ?? "",
                fine_print: bundle.refund_policy.fine_print ?? "",
                updated_at: "",
              },
          bundle_products: bundle.products.map((bundleProduct) => ({
            ...bundleProduct,
            price: computeStandalonePrice(bundleProduct),
            variant:
              bundleProduct.variants?.list.find(({ id }) => id === bundleProduct.variants?.selected_id)?.name ?? null,
          })),
          public_files: bundle.public_files,
          audio_previews_enabled: bundle.audio_previews_enabled,
        }}
        purchase={null}
        selection={{
          quantity: 1,
          optionId: null,
          recurrence: null,
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
