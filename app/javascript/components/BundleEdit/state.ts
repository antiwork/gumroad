import * as React from "react";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { AssetPreview, CardProduct, CustomButtonTextOption, RatingsWithPercentages } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Seller } from "$app/components/Product";
import { Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection, PublicFileWithStatus } from "$app/components/ProductEdit/state";

export const BundleEditContext = React.createContext<{
  bundle: Bundle;
  updateBundle: (update: Partial<Bundle> | ((bundle: Bundle) => void)) => void;
  id: string;
  uniquePermalink: string;
  currencyType: CurrencyCode;
  thumbnail: Thumbnail | null;
  salesCountForInventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profileSections: ProfileSection[];
  refundPolicies: OtherRefundPolicy[];
  productsCount: number;
  hasOutdatedPurchases: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
} | null>(null);
export const useBundleEditContext = () => assertDefined(React.useContext(BundleEditContext));

export type BundleProduct = CardProduct & {
  is_quantity_enabled: boolean;
  quantity: number;
  variants: {
    selected_id: string;
    list: {
      id: string;
      name: string;
      description: string;
      price_difference: number;
    }[];
  } | null;
};

export type Bundle = {
  name: string;
  description: string;
  custom_permalink: string | null;
  price_cents: number;
  suggested_price_cents: number | null;
  eligible_for_installment_plans: boolean;
  allow_installment_plan: boolean;
  installment_plan: { number_of_installments: number } | null;
  customizable_price: boolean;
  collaborating_user: Seller | null;
  custom_button_text_option: CustomButtonTextOption | null;
  custom_summary: string | null;
  custom_attributes: Attribute[];
  max_purchase_count: number | null;
  quantity_enabled: boolean;
  should_show_sales_count: boolean;
  is_epublication: boolean;
  product_refund_policy_enabled: boolean;
  refund_policy: RefundPolicy;
  taxonomy_id: string | null;
  tags: string[];
  display_product_reviews: boolean;
  is_adult: boolean;
  discover_fee_per_thousand: number;
  section_ids: string[];
  is_published: boolean;
  covers: AssetPreview[];
  products: BundleProduct[];
  public_files: PublicFileWithStatus[];
  audio_previews_enabled: boolean;
};

export const computeStandalonePrice = (bundleProduct: BundleProduct) =>
  (bundleProduct.price_cents +
    (bundleProduct.variants?.list.find(({ id }) => id === bundleProduct.variants?.selected_id)?.price_difference ??
      0)) *
  bundleProduct.quantity;
