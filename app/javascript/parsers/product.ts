import ProductSectionSchema from "$app/json_schemas/seller_profile_products_section";
import { CurrencyCode } from "$app/utils/currency";
import { RecurrenceId } from "$app/utils/recurringPricing";

export type AssetPreview = {
  type: "video" | "image" | "unsplash" | "oembed"; // Creating new Unsplash previews is deprecated
  filetype: string | null;
  id: string;
  url: string;
  original_url: string;
  thumbnail: string | null;
  width: number | null;
  height: number | null;
  native_width: number | null;
  native_height: number | null;
};

export type ProductNativeType =
  | "digital"
  | "course"
  | "ebook"
  | "newsletter"
  | "membership"
  | "podcast"
  | "audiobook"
  | "physical"
  | "bundle"
  | ProductServiceType;

export type ProductServiceType = "commission" | "call" | "coffee";

export type Ratings = { count: number; average: number };

export type RatingsWithPercentages = Ratings & { percentages: Tuple<number, 5> };

export type CardProduct = {
  id: string;
  permalink: string;
  name: string;
  seller: { id: string; name: string; profile_url: string; avatar_url: string | null } | null;
  ratings: Ratings | null;
  price_cents: number;
  original_price_cents?: number;
  currency_code: CurrencyCode;
  thumbnail_url: string | null;
  native_type: ProductNativeType;
  url: string;
  is_pay_what_you_want: boolean;
  quantity_remaining: number | null;
  is_sales_limited: boolean;
  duration_in_months: number | null;
  recurrence: RecurrenceId | null;
  description?: string;
};

export type AnalyticsData = {
  google_analytics_id: string | null;
  facebook_pixel_id: string | null;
  free_sales: boolean;
};

export type FreeTrialDurationUnit = "month" | "hour" | "week";
export type FreeTrialDuration = { amount: number; unit: FreeTrialDurationUnit };
export type FreeTrial = { duration: FreeTrialDuration };

export type CustomFieldDescriptor = {
  id: string;
  type: "text" | "terms" | "checkbox";
  name: string;
  required: boolean;
  collect_per_product: boolean;
};

export const SORT_KEYS = [
  "default",
  "newest",
  "hot_and_new",
  "highest_rated",
  "most_reviewed",
  "price_asc",
  "price_desc",
] as const;
export type SortKey = (typeof SORT_KEYS)[number];
export const PROFILE_SORT_KEYS = ProductSectionSchema.properties.default_product_sort.enum;
export type ProfileSortKey = (typeof PROFILE_SORT_KEYS)[number];

export const COMMISSION_DEPOSIT_PROPORTION = 0.5;

export const CUSTOM_BUTTON_TEXT_OPTIONS = ["i_want_this_prompt", "buy_this_prompt", "pay_prompt"] as const;
export const COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS = ["donate_prompt", "support_prompt", "tip_prompt"] as const;

export type CustomButtonTextOption =
  | (typeof CUSTOM_BUTTON_TEXT_OPTIONS)[number]
  | (typeof COFFEE_CUSTOM_BUTTON_TEXT_OPTIONS)[number];
