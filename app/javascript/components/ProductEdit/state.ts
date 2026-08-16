import * as React from "react";

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
  // The variant's snapshot timestamp as served by the server (unset for
  // variants created in this editor session). Echoed back with each save so
  // the server can reject writes built from a stale snapshot (see the
  // server's Product::StaleContentWriteGuard); refreshed from each save
  // response. For a membership tier it covers the tier's prices too, which
  // are stored separately from the tier itself.
  updated_at?: string;
  max_purchase_count: number | null;
  integrations: Record<keyof Product["integrations"], boolean>;
  // Which of this variant's integrations were connected as of the last
  // committed state — the version-scoped twin of Product["loaded_integrations"].
  // Set by the server on load and refreshed after each successful save, so
  // switching one off is recognised as a removal rather than inferred from the
  // checkbox map. Unset for variants created in this session.
  loaded_integrations?: Record<string, boolean>;
  newlyAdded?: boolean;
  rich_content: Page[];
  // Whether the variant has files attached directly (legacy products predating
  // embedded rich-content files). Set by the server; variants created in this
  // editor session leave it unset. Used by the save-time deletion summary to
  // treat file-only variants as content-bearing, matching the server guard.
  has_files?: boolean;
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

export type OfferCode = {
  id: string;
  code: string;
  name: string;
  discount: Discount;
};

export type TaxonomyAttribute = {
  taxonomy_id: string;
  name: string;
  label: string;
  value_type: "enum" | "boolean" | "number";
  values: string[];
};

export type TaxonomyAttributeValue = string | boolean | number | null;

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
  custom_html: string | null;
  custom_view_content_button_text: string | null;
  custom_view_content_button_text_max_length: number;
  custom_receipt_text: string | null;
  custom_receipt_text_max_length: number;
  custom_attributes: Attribute[];
  taxonomy_attribute_values: Record<string, TaxonomyAttributeValue>;
  inferred_taxonomy_attribute_values: Record<string, TaxonomyAttributeValue>;
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
  default_offer_code_id?: string | null;
  default_offer_code: OfferCode | null;
  public_files: PublicFileWithStatus[];
  community_chat_enabled: boolean;
  // External ids of variants / content pages the seller explicitly deleted in
  // this editor session (via the respective confirmation modals). Sent with the
  // save payload so the server can tell an intentional deletion apart from an
  // outdated or blind payload that would otherwise silently wipe content.
  confirmed_removed_variant_ids?: string[];
  confirmed_removed_rich_content_ids?: string[];
  // Server-issued snapshot of which integrations were connected when this
  // editing session loaded. Used to tell "seller unchecked this" apart from
  // "was never on" — see buildDeletionOperations.
  loaded_integrations?: Record<string, boolean>;
  // External ids of version-level pages the seller chose to KEEP in the
  // hidden-content conflict dialog ("Keep version content"). They're hidden
  // from this editor session by the shared-content flag, so they can't appear
  // in the payload — this tells the server their absence is not a deletion.
  preserved_rich_content_ids?: string[];
  // The save contract (gumroad-private#1379).
  //
  // `editor_revision` is the snapshot token the server issued when this editor
  // session loaded. The server compares it per record and refuses to act on a
  // *deletion* built from a snapshot that has moved on — a second tab, or this
  // tab left open while someone else saved. Writes are not gated on it: a stale
  // tab overwriting a title is recoverable, a stale tab deleting a page is not.
  //
  // `deletion_operations` is the ONLY way this client can remove anything.
  // Under the contract an absent or empty collection means "no changes", so
  // omitting a record no longer deletes it — the seller's removals have to be
  // stated explicitly, which is what makes an accidental wipe impossible rather
  // than merely unlikely. Derived from the confirmed-removal lists at send time
  // (see buildDeletionOperations); deliberately not a field on this type, so
  // nothing can pre-set it and outrank them.
  editor_revision?: string | null;
} & (
  | { native_type: "call"; variants: Duration[] }
  | { native_type: "membership"; variants: Tier[] }
  | { native_type: Exclude<ProductNativeType, "call" | "membership">; variants: Version[] }
);

// The five collections the editor save can destroy, and the only two ways to
// ask for a removal (gumroad-private#1379).
//
//   deleted_ids         — remove exactly these records, nothing else
//   cleared_collections — remove everything the collection held when this
//                         editor session loaded
//
// Neither can be produced by accident: omitting a record, sending `[]`, or
// sending a malformed value all mean "no changes" now. Emptying a collection is
// something the seller has to actually ask for.
export type SaveContractCollection = "rich_content" | "variants" | "files" | "public_files" | "integrations";

export type DeletionOperations = {
  deleted_ids: Partial<Record<SaveContractCollection, string[]>>;
  cleared_collections: SaveContractCollection[];
  // Deletions scoped to ONE version/tier rather than to the product, keyed by
  // that version's id. Version-level integrations live on a join between the
  // version and the integration, so "disconnect Discord from this tier" cannot
  // be expressed as a product-level id: the same integration may legitimately
  // stay connected on a sibling tier. Absent means "no version-scoped
  // deletions", exactly like the product-level lists.
  variant_deleted_ids?: Record<string, Partial<Record<SaveContractCollection, string[]>>>;
};

export type ProfileSection = { id: string; header: string | null; product_names: string[]; default: boolean };

// What the header's save indicator reports. Beyond the base three,
// "uploading" and "review_deletions" name the states where autosave is
// deliberately waiting on the seller, and "failed" appears once an automatic
// save has spent its retry budget.
export type SaveStatus = "saved" | "unsaved" | "saving" | "uploading" | "review_deletions" | "failed";
export type ShippingCountry = { code: string; name: string };

export type ContentUpdates = {
  uniquePermalinkOrVariantIds: string[];
  // True when an automatic save produced this prompt — the alert copy must
  // not thank the seller for a click they never made. Absent on the flag-off
  // path, which stays byte-identical to the pre-autosave shape.
  automatic?: boolean;
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
  taxonomyAttributes: TaxonomyAttribute[];
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
  saveStatus: SaveStatus;
  autosaveEnabled: boolean;
  // Session-only. Pause stops the debounce without turning the seller flag off;
  // Resume schedules the usual save if the editor is dirty.
  autosavePaused: boolean;
  setAutosavePaused: (paused: boolean) => void;
  // Resolves true only when the save request actually succeeded (false on
  // request failure or when the seller cancels the deletion confirmation) —
  // callers chaining navigation on save() must check it before proceeding.
  save: () => Promise<boolean>;
  // Client-generated id → canonical server id, accumulated separately by
  // record type. Variant and page external ids can collide because both encode
  // a numeric database id, so a shared map cannot safely follow mapping chains.
  variantIdMappings: Record<string, string>;
  richContentIdMappings: Record<string, string>;
  fileIdMappings: Record<string, string>;
  // Canonical page id → file ids removed by the last successful save. The
  // content tab uses this one-shot response signal to reconcile its mounted
  // TipTap document; changing product state alone does not update that editor.
  richContentRemovedFileEmbedIds: Record<string, string[]>;
  googleClientId: string;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellationDiscountsEnabled: boolean;
  // The sender line receipt emails actually go out with (mirrors CustomerMailer#receipt),
  // shown in the Receipt tab's email-style preview chrome.
  receiptEmailFrom: string;
  priceCheckerEnabled: boolean;
  customHtmlPagesEnabled: boolean;
  // Hostnames this seller controls (their subdomain, their live custom domain).
  // The landing-page preview only follows a navigation request from the
  // sandboxed seller HTML when the destination is one of these.
  customHtmlStoreHostnames: string[];
  // Gumroad's own global nav destinations (My Downloads, cart) that the preview
  // will follow on an exact-path match, and the hosts they may appear on.
  customHtmlGlobalNavHosts: string[];
  customHtmlGlobalNavPaths: string[];
  contentUpdates: ContentUpdates;
  setContentUpdates: React.Dispatch<React.SetStateAction<ContentUpdates>>;
  filesById: Map<string, FileEntry>;
  aiGenerated: boolean;
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

export const isFileUploading = (file: { status?: { type: string; uploadStatus?: { type: string } } }) =>
  file.status?.type === "unsaved" && file.status.uploadStatus?.type === "uploading";

export type FileEntry = {
  display_name: string;
  description: string | null;
  extension: string | null;
  file_size: null | number;
  is_pdf: boolean;
  pdf_stamp_enabled: boolean;
  hide_kindle_and_read_buttons: boolean;
  is_streamable: boolean;
  stream_only: boolean;
  is_transcoding_in_progress: boolean;
  // Pixel dimensions of the video, when we know them, so the editor's preview
  // frame can match the file's real shape instead of assuming 16:9. Null for
  // non-video files and for older uploads whose dimensions were never recorded.
  width?: number | null;
  height?: number | null;
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
