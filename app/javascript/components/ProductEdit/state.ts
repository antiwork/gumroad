import * as React from "react";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import {
  AssetPreview,
  CustomButtonTextOption,
  FreeTrialDurationUnit,
  ProductNativeType,
  RatingsWithPercentages,
} from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { RecurrenceId } from "$app/utils/recurringPricing";

import { PublicFile, Seller } from "$app/components/Product";
import { SubtitleFile } from "$app/components/SubtitleList/Row";

import { Page } from "./ContentTab/PageTab";
import { Attribute } from "./ProductTab/AttributesEditor";
import { CircleIntegration } from "./ProductTab/CircleIntegrationEditor";
import { DiscordIntegration } from "./ProductTab/DiscordIntegrationEditor";
import { GoogleCalendarIntegration } from "./ProductTab/GoogleCalendarIntegrationEditor";
import { RefundPolicy } from "./RefundPolicy";

export type Variant = {
  id: string;
  name: string;
  description: string;
  max_purchase_count: number | null;
  integrations: Record<keyof Product["integrations"], boolean>;
  newlyAdded?: boolean;
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
  newlyAdded?: boolean;
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

export type Product = {
  name: string;
  description: string;
  custom_permalink: string | null;
  price_cents: number;
  suggested_price_cents: number | null;
  customizable_price: boolean;
  eligible_for_installment_plans: boolean;
  allow_installment_plan: boolean;
  installment_plan: InstallmentPlan | null;
  custom_button_text_option: CustomButtonTextOption | null;
  custom_summary: string | null;
  custom_attributes: Attribute[];
  file_attributes: Attribute[];
  max_purchase_count: number | null;
  quantity_enabled: boolean;
  can_enable_quantity: boolean;
  should_show_sales_count: boolean;
  hide_sold_out_variants: boolean;
  is_epublication: boolean;
  product_refund_policy_enabled: boolean;
  refund_policy: RefundPolicy;
  is_published: boolean;
  free_trial_enabled: boolean;
  free_trial_duration_amount: 1 | null;
  free_trial_duration_unit: FreeTrialDurationUnit | null;
  should_include_last_post: boolean;
  should_show_all_posts: boolean;
  block_access_after_membership_cancellation: boolean;
  duration_in_months: number | null;
  subscription_duration: RecurrenceId | null;
  integrations: {
    discord: DiscordIntegration;
    circle: CircleIntegration;
    google_calendar: GoogleCalendarIntegration;
  };
  covers: AssetPreview[];
  availabilities: Availability[];
  section_ids: string[];
  taxonomy_id: string | null;
  tags: string[];
  display_product_reviews: boolean;
  is_adult: boolean;
  discover_fee_per_thousand: number;
  shipping_destinations: ShippingDestination[];
  custom_domain: string;
  collaborating_user: Seller | null;
  rich_content: Page[];
  files: FileEntry[];
  has_same_rich_content_for_all_variants: boolean;
  is_multiseat_license: boolean;
  call_limitation_info: CallLimitationInfo | null;
  require_shipping: boolean;
  cancellation_discount: CancellationDiscount | null;
  public_files: PublicFileWithStatus[];
  audio_previews_enabled: boolean;
  community_chat_enabled: boolean | null;
} & (
  | { native_type: "call"; variants: Duration[] }
  | { native_type: "membership"; variants: Tier[] }
  | { native_type: Exclude<ProductNativeType, "call" | "membership">; variants: Version[] }
);

export type ProfileSection = { id: string; header: string | null; product_names: string[]; default: boolean };

export type ShippingCountry = { code: string; name: string };

export type ContentUpdates = {
  uniquePermalinkOrVariantIds: string[];
} | null;

export const ProductEditContext = React.createContext<{
  id: string;
  product: Product;
  uniquePermalink: string;
  updateProduct: (update: Partial<Product> | ((product: Product) => void)) => void;
  thumbnail: Thumbnail | null;
  refundPolicies: OtherRefundPolicy[];
  currencyType: CurrencyCode;
  setCurrencyType: (newCurrencyCode: CurrencyCode) => void;
  isListedOnDiscover: boolean;
  isPhysical: boolean;
  profileSections: ProfileSection[];
  taxonomies: Taxonomy[];
  earliestMembershipPriceChangeDate: Date;
  customDomainVerificationStatus: { success: boolean; message: string } | null;
  salesCountForInventory: number;
  successfulSalesCount: number;
  ratings: RatingsWithPercentages;
  seller: Seller;
  existingFiles: ExistingFileEntry[];
  setExistingFiles: React.Dispatch<React.SetStateAction<ExistingFileEntry[]>>;
  awsKey: string;
  s3Url: string;
  availableCountries: ShippingCountry[];
  saving: boolean;
  save: () => Promise<void>;
  googleClientId: string;
  googleCalendarEnabled: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellationDiscountsEnabled: boolean;
  contentUpdates: ContentUpdates;
  setContentUpdates: React.Dispatch<React.SetStateAction<ContentUpdates>>;
} | null>(null);
export const useProductEditContext = () => assertDefined(React.useContext(ProductEditContext));

//TODO: clean up this legacy file state
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
  id: string; // id is either server ID or, in case of unsaved dropbox files, `drop_[external_id]`
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
