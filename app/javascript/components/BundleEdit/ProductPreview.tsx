import * as React from "react";

import { AssetPreview, CustomButtonTextOption, RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";

import { useProductUrl } from "$app/components/BundleEdit/Layout";
import { BundleProduct } from "$app/components/BundleEdit/types";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Product, Seller } from "$app/components/Product";
import { Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { RefundPolicy, RefundPolicyModalPreview } from "$app/components/ProductEdit/RefundPolicy";
import { PublicFileWithStatus } from "$app/components/ProductEdit/state";

const computeStandalonePrice = (bundleProduct: BundleProduct) =>
  (bundleProduct.price_cents +
    (bundleProduct.variants?.list.find(({ id }) => id === bundleProduct.variants?.selected_id)?.price_difference ??
      0)) *
  bundleProduct.quantity;

type ProductPreviewBundle = {
  name: string;
  description: string;
  covers: AssetPreview[];
  collaborating_user: Seller | null;
  customizable_price: boolean;
  price_cents: number;
  suggested_price_cents: number | null;
  max_purchase_count: number | null;
  allow_installment_plan: boolean;
  installment_plan: { number_of_installments: number } | null;
  display_product_reviews: boolean;
  quantity_enabled: boolean;
  should_show_sales_count: boolean;
  custom_button_text_option: CustomButtonTextOption | null;
  custom_summary: string | null;
  custom_attributes: Attribute[];
  refund_policy: RefundPolicy;
  public_files: PublicFileWithStatus[];
  audio_previews_enabled: boolean;
  is_published: boolean;
  custom_permalink?: string | null;
  products: BundleProduct[];
};

type ProductPreviewProps = {
  bundle: ProductPreviewBundle;
  id: string;
  uniquePermalink: string;
  currencyType: CurrencyCode;
  salesCountForInventory: number;
  ratings: RatingsWithPercentages;
  sellerRefundPolicyEnabled: boolean;
  sellerRefundPolicy: Pick<RefundPolicy, "title" | "fine_print">;
  showRefundPolicyModal?: boolean;
};

export const ProductPreview = ({
  bundle,
  id,
  uniquePermalink,
  currencyType,
  salesCountForInventory,
  ratings,
  sellerRefundPolicyEnabled,
  sellerRefundPolicy,
  showRefundPolicyModal,
}: ProductPreviewProps) => {
  const currentSeller = useCurrentSeller();
  const url = useProductUrl(uniquePermalink, bundle.custom_permalink);

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
