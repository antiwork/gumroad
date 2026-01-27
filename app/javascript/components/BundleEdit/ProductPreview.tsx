import * as React from "react";

import { Bundle, computeStandalonePrice } from "$app/components/BundleEdit/state";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Product } from "$app/components/Product";
import { RefundPolicyModalPreview, RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { CurrencyCode } from "$app/utils/currency";
import { RatingsWithPercentages } from "$app/parsers/product";

type ProductPreviewProps = {
  bundle: Bundle;
  showRefundPolicyModal?: boolean;
  id?: string;
  uniquePermalink?: string;
  currencyType?: CurrencyCode;
  salesCountForInventory?: number;
  ratings?: RatingsWithPercentages;
  sellerRefundPolicyEnabled?: boolean;
  sellerRefundPolicy?: Pick<RefundPolicy, "title" | "fine_print">;
};

export const ProductPreview = ({
  bundle,
  showRefundPolicyModal,
  id,
  uniquePermalink,
  currencyType = "usd",
  salesCountForInventory = 0,
  ratings = { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
  sellerRefundPolicyEnabled = false,
  sellerRefundPolicy = { title: "", fine_print: "" },
}: ProductPreviewProps) => {
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  
  const url = Routes.short_link_url(bundle.custom_permalink ?? uniquePermalink ?? "", {
    host: currentSeller?.subdomain ?? appDomain,
  });

  if (!currentSeller) return null;

  return (
    <>
      <RefundPolicyModalPreview open={showRefundPolicyModal ?? false} refundPolicy={bundle.refund_policy} />
      <Product
        product={{
          id: id ?? "",
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
          is_physical: false,
          custom_view_content_button_text: null,
          permalink: uniquePermalink ?? "",
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
          refund_policy: sellerRefundPolicyEnabled
            ? {
                title: sellerRefundPolicy.title,
                fine_print: sellerRefundPolicy.fine_print ?? "",
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
