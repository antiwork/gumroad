import { cast } from "$app/utils/cast";
import { CurrencyCode } from "$app/utils/currency";
import { request, ResponseError } from "$app/utils/request";

import { FileItem } from "$app/components/EmailAttachments";

export type Installment = {
  external_id?: string;
  display_type: "published" | "scheduled" | "draft";
  name: string;
  message: string;
  published_at: string | null;
  updated_at: string;
  stream_only: boolean;
  streamable: boolean;
  send_emails: boolean;
  shown_on_profile: boolean;
  installment_type: string;
  bought_products?: string[];
  not_bought_products?: string[];
  bought_variants?: string[];
  not_bought_variants?: string[];
  unique_permalink?: string;
  variant_external_id?: string;
  affiliate_products?: string[];
  waitlisted_products?: string[];
  not_clicked_post_id?: string | null;
  opened_post_id?: string | null;
  paid_more_than_cents: number | null;
  paid_less_than_cents: number | null;
  created_after?: string;
  created_before?: string;
  bought_from?: string;
  active_customers_only?: boolean;
  minimum_license_uses?: number | null;
  allow_comments: boolean;
  full_url: string;
  has_been_blasted: boolean;
  files: FileItem[];
  shown_in_profile_sections?: string[];
};

export type SavedInstallment = Installment & {
  external_id: string;
  shown_in_profile_sections: string[];
};

export type PublishedInstallment = SavedInstallment & {
  external_id: string;
  sent_count: number | null;
  click_count: number;
  click_rate: number | null;
  open_count: number;
  open_rate: number | null;
  view_count: number | null;
  published_at: string;
  non_opener_resends: {
    requested_at: string;
    delivery_count: number;
    completed: boolean;
    expired: boolean;
    open_count: number | null;
    open_rate: number | null;
  }[];
  delivery: {
    status: "sent" | "sending" | "waiting" | "incomplete" | "expired" | "abandoned" | "stopped" | "too_few_recipients";
    delivered_count: number;
    remaining_count: number | null;
    scheduled_for: string | null;
    retrying: boolean;
  } | null;
  // Every send expired, so there are no recipients to resend to.
  never_reached_anyone: boolean;
};

export type ScheduledInstallment = SavedInstallment & {
  external_id: string;
  recipient_description: string | null;
  to_be_published_at: string;
};

export type DraftInstallment = SavedInstallment & {
  external_id: string;
  recipient_description: string | null;
};

export type Pagination = {
  count: number;
  next: number | null;
};

export type AudienceType = "everyone" | "customers" | "followers" | "affiliates";

export type EmailTab = "published" | "scheduled" | "drafts" | "subscribers";

export const TYPE_TO_TAB: Record<string, EmailTab> = {
  published: "published",
  scheduled: "scheduled",
  draft: "drafts",
};

export type InstallmentFormContext = {
  audience_types: AudienceType[];
  products: { permalink: string; name: string; archived: boolean; variants: { id: string; name: string }[] }[];
  affiliate_products: { permalink: string; name: string; archived: boolean }[];
  // The seller's products that have waitlist signups.
  waitlist_products: { permalink: string; name: string }[];
  // The seller's posts that were emailed to buyers, usable as a "has not clicked" reference.
  emailed_posts: { external_id: string; name: string }[];
  timezone: string;
  currency_type: CurrencyCode;
  countries: string[];
  profile_sections: { id: string; name: string | null }[];
  has_scheduled_emails: boolean;
  aws_access_key_id: string;
  s3_url: string;
  user_id: string;
  allow_comments_by_default: boolean;
  from_tab: EmailTab | null;
};

// Mirrors Installment::MINIMUM_BEHAVIOR_SEGMENT_SIZE: the server withholds smaller behavior-segment counts.
export const MINIMUM_BEHAVIOR_SEGMENT_SIZE = 5;

export async function getAudienceCount(externalId: string) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_installment_audience_count_path(externalId),
  });

  if (!response.ok) throw new ResponseError();
  return cast<{ count: number | null }>(await response.json());
}

type RecipientCountRequestPayload = {
  paid_more_than_cents: number | null;
  paid_less_than_cents: number | null;
  bought_from: string | null;
  active_customers_only?: boolean;
  minimum_license_uses: number | null;
  installment_type: string;
  created_after: string;
  created_before: string;
  bought_products: string[] | null;
  bought_variants: string[] | null;
  not_bought_products: string[] | null;
  not_bought_variants: string[] | null;
  affiliate_products: string[] | null;
  waitlisted_products: string[] | null;
  not_clicked_post_id: string | null;
  opened_post_id: string | null;
};
export function getRecipientCount(requestPayload: RecipientCountRequestPayload) {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.internal_installment_recipient_count_path(requestPayload),
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<{ recipient_count: number | null; audience_count: number }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
}

export type ClickedUrl = { url: string; count: number };

export async function getClickedUrls(externalId: string, abortSignal?: AbortSignal) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_installment_clicked_urls_path(externalId),
    abortSignal,
  });

  if (!response.ok) throw new ResponseError();
  return cast<{ clicked_urls: ClickedUrl[] }>(await response.json()).clicked_urls;
}

export async function getNonOpenerCount(externalId: string) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_installment_non_opener_resend_path(externalId),
  });

  if (!response.ok) throw new ResponseError();
  // `count` is null when the audience is too large to count within the request; the
  // resend itself still works (recipients are resolved in a background job).
  return cast<{ count: number | null; recently_resent: boolean; audience_filtered_out: boolean }>(
    await response.json(),
  );
}

export async function resendToNonOpeners(externalId: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_installment_non_opener_resend_path(externalId),
  });

  const json: unknown = await response.json();
  if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
  return cast<{ success: boolean }>(json);
}

export async function sendToRemaining(externalId: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_installment_remaining_send_path(externalId),
  });

  const json: unknown = await response.json();
  if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
  return cast<{ success: boolean }>(json);
}

export async function previewInstallment(externalId: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_installment_preview_email_path(externalId),
  });

  if (!response.ok) throw new ResponseError(cast<{ message: string }>(await response.json()).message);
}
