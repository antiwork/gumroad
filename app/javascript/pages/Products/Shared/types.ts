// Shared types for Product Edit Inertia pages
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { Discount } from "$app/parsers/checkout";
import {
  AssetPreview,
  CustomButtonTextOption,
  FreeTrialDurationUnit,
  ProductNativeType,
  RatingsWithPercentages,
} from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { RecurrenceId } from "$app/utils/recurringPricing";

import { PublicFile, Seller } from "$app/components/Product";
import { Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { CircleIntegration } from "$app/components/ProductEdit/ProductTab/CircleIntegrationEditor";
import { DiscordIntegration } from "$app/components/ProductEdit/ProductTab/DiscordIntegrationEditor";
import { GoogleCalendarIntegration } from "$app/components/ProductEdit/ProductTab/GoogleCalendarIntegrationEditor";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { SubtitleFile } from "$app/components/SubtitleList/Row";

export type Variant = {
  id: string;
  name: string;
  description: string;
  max_purchase_count: number | null;
  integrations: Record<string, boolean>;
  rich_content: Page[];
  sales_count_for_inventory?: number;
  active_subscribers_count?: number;
};

export type Version = Variant & {
  price_difference_cents: number | null;
};

export type Duration = Variant & {
  duration_in_minutes: number | null;
  price_difference_cents: number | null;
};

export type Availability = {
  id: string;
  start_time: string;
  end_time: string;
};

export type ProfileSection = {
  id: string;
  header: string;
  product_names: string[];
  default: boolean;
};

export type RecurrencePriceValue =
  | { enabled: false; price_cents?: number | null }
  | { enabled: true; price_cents: number | null; suggested_price_cents: number | null };

export type Tier = Variant & {
  customizable_price: boolean;
  apply_price_changes_to_existing_memberships: boolean;
  subscription_price_change_effective_date: string | null;
  subscription_price_change_message: string | null;
  recurrence_price_values: {
    [key in RecurrenceId]: RecurrencePriceValue;
  };
};

export type ShippingDestination = {
  country_code: string;
  one_item_rate_cents: number | null;
  multiple_items_rate_cents: number | null;
};

export type CallLimitationInfo = {
  minimum_notice_in_minutes: number | null;
  maximum_calls_per_day: number | null;
};

export type CancellationDiscount = {
  discount: { type: "fixed"; cents: number } | { type: "percent"; percents: number };
  duration_in_billing_cycles: number | null;
};

export type InstallmentPlan = {
  number_of_installments: number;
};

export type OfferCode = {
  id: string;
  code: string;
  name: string;
  discount: Discount;
};

export type Product = {
  name: string;
  description?: string;
  custom_permalink: string | null;
  price_cents?: number;
  suggested_price_cents?: number | null;
  customizable_price?: boolean;
  eligible_for_installment_plans?: boolean;
  allow_installment_plan?: boolean;
  installment_plan?: InstallmentPlan | null;
  custom_button_text_option?: CustomButtonTextOption | null;
  custom_summary?: string | null;
  custom_view_content_button_text?: string | null;
  custom_view_content_button_text_max_length?: number;
  custom_receipt_text?: string | null;
  custom_receipt_text_max_length?: number;
  custom_attributes?: Attribute[];
  file_attributes?: Attribute[];
  max_purchase_count?: number | null;
  quantity_enabled?: boolean;
  can_enable_quantity?: boolean;
  should_show_sales_count?: boolean;
  hide_sold_out_variants?: boolean;
  is_epublication?: boolean;
  product_refund_policy_enabled?: boolean;
  refund_policy?: RefundPolicy;
  is_published?: boolean;
  free_trial_enabled?: boolean;
  free_trial_duration_amount?: 1 | null;
  free_trial_duration_unit?: FreeTrialDurationUnit | null;
  should_include_last_post?: boolean;
  should_show_all_posts?: boolean;
  block_access_after_membership_cancellation?: boolean;
  duration_in_months?: number | null;
  subscription_duration?: RecurrenceId | null;
  integrations?: {
    discord: DiscordIntegration;
    circle: CircleIntegration;
    google_calendar: GoogleCalendarIntegration;
  };
  covers?: AssetPreview[];
  availabilities?: Availability[];
  section_ids?: string[];
  taxonomy_id?: string | null;
  tags?: string[];
  display_product_reviews?: boolean;
  is_adult?: boolean;
  discover_fee_per_thousand?: number;
  shipping_destinations?: ShippingDestination[];
  custom_domain?: string;
  collaborating_user?: Seller | null;
  rich_content?: Page[];
  files?: FileEntry[];
  has_same_rich_content_for_all_variants?: boolean;
  is_multiseat_license?: boolean;
  call_limitation_info?: CallLimitationInfo | null;
  require_shipping?: boolean;
  cancellation_discount?: CancellationDiscount | null;
  default_offer_code_id?: string | null;
  default_offer_code?: OfferCode | null;
  public_files?: PublicFileWithStatus[];
  audio_previews_enabled?: boolean;
  community_chat_enabled?: boolean | null;
  native_type?: ProductNativeType;
  variants?: Variant[] | Version[] | Duration[] | Tier[];
};

export type ProfileSection = {
  id: string;
  header: string | null;
  product_names: string[];
  default: boolean;
};

export type ShippingCountry = { code: string; name: string };

type UploadProgress = { percent: number; bitrate: number };

type FileStatus =
  | { type: "saved" }
  | { type: "existing" }
  | { type: "dropbox"; externalId: string; uploadState: string }
  | {
      type: "unsaved";
      uploadStatus: { type: "uploaded" } | { type: "uploading"; progress: UploadProgress };
      url: string;
    };

export type FileEntry = {
  display_name: string;
  description: string | null;
  extension: string | null;
  file_size: null | number;
  is_pdf: boolean;
  pdf_stamp_enabled: boolean;
  is_streamable: boolean;
  stream_only: boolean;
  is_transcoding_in_progress: boolean;
  id: string;
  url: string | null;
  isbn?: string | null;
  subtitle_files: SubtitleFile[];
  status: FileStatus | { type: "removed"; previousStatus: FileStatus };
  thumbnail: ThumbnailFile | null;
};

export type PublicFileWithStatus = PublicFile & { status?: FileStatus };

export type ExistingFileEntry = FileEntry & { attached_product_name: string | null };

export type ThumbnailFile = {
  url: string;
  signed_id: string;
  status: { type: "saved" } | { type: "existing" } | { type: "unsaved" };
};

// Common props shared across all product edit pages
export type BaseProductEditPageProps = {
  id: string;
  unique_permalink: string;
  seller: Seller;
};
