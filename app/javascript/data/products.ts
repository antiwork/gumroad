import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type SortKey = "name" | "successful_sales_count" | "revenue" | "display_price_cents" | "status" | "cut";

export type Membership = {
  id: number;
  edit_url: string;
  is_duplicating: boolean;
  has_duration: boolean;
  successful_sales_count: number;
  remaining_for_sale_count: number | null;
  monthly_recurring_revenue: number;
  name: string;
  permalink: string;
  price_formatted: string;
  display_price_cents: number;
  revenue: number;
  revenue_pending: number;
  status: "preorder" | "published" | "unpublished";
  thumbnail: { url: string } | null;
  url: string;
  url_without_protocol: string;
  can_edit: boolean;
  can_duplicate: boolean;
  can_destroy: boolean;
  can_archive: boolean;
  can_unarchive: boolean;
};

export type Product = {
  id: number;
  edit_url: string;
  is_duplicating: boolean;
  name: string;
  permalink: string;
  price_formatted: string;
  revenue: number;
  display_price_cents: number;
  successful_sales_count: number;
  remaining_for_sale_count: number | null;
  status: "preorder" | "published" | "unpublished";
  thumbnail: { url: string } | null;
  url: string;
  url_without_protocol: string;
  can_edit: boolean;
  can_duplicate: boolean;
  can_destroy: boolean;
  can_archive: boolean;
  can_unarchive: boolean;
};

export type RecurringProductType = "membership" | "newsletter" | "podcast";

export async function getFolderArchiveDownloadUrl(request_url: string) {
  const res = await request({
    method: "GET",
    accept: "json",
    url: request_url,
  });
  if (!res.ok) return { url: null };
  return cast<{ url: string | null }>(await res.json());
}

export async function getProductFileDownloadInfos(request_url: string) {
  const res = await request({
    method: "GET",
    accept: "json",
    url: request_url,
  });
  if (!res.ok) return [];
  return cast<{ files: { url: string; filename: string | null }[] }>(await res.json()).files;
}
