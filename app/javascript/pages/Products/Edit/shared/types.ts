// app/javascript/pages/Products/Edit/shared/types.ts
//
// Re-exports the Props type from the existing ProductEditPage server component
// so all four Inertia tab pages share the same prop contract.

import type { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import type { Thumbnail } from "$app/data/thumbnails";
import type { RatingsWithPercentages } from "$app/parsers/product";
import type { CurrencyCode } from "$app/utils/currency";
import type { Taxonomy } from "$app/utils/discover";
import type { Seller } from "$app/components/Product";
import type { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import type {
  Product,
  ProfileSection,
  ShippingCountry,
  ExistingFileEntry,
} from "$app/components/ProductEdit/state";

export interface EditPageProps {
  product: Product;
  id: string;
  unique_permalink: string;
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  currency_type: CurrencyCode;
  is_tiered_membership: boolean;
  is_listed_on_discover: boolean;
  is_physical: boolean;
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  earliest_membership_price_change_date: string;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  sales_count_for_inventory: number;
  successful_sales_count: number;
  ratings: RatingsWithPercentages;
  seller: Seller;
  existing_files: ExistingFileEntry[];
  aws_key: string;
  s3_url: string;
  available_countries: ShippingCountry[];
  google_client_id: string;
  google_calendar_enabled: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellation_discounts_enabled: boolean;
  ai_generated: boolean;
}
