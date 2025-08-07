import { cast } from "ts-safe-cast";

import { RecurrenceId } from "$app/utils/recurringPricing";
import { ResponseError, request } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

export type SortKey = "name" | "successful_sales_count" | "revenue" | "display_price_cents" | "status" | "cut";

export type MembershipsParams = {
  page: number | null;
  query: string | null;
  sort?: Sort<SortKey> | null;
};

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

export type ProductsParams = {
  page: number | null;
  query: string | null;
  sort?: Sort<SortKey> | null;
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
export type OneTimeDigitalProductType =
  | "audiobook"
  | "bundle"
  | "call"
  | "coffee"
  | "commission"
  | "course"
  | "digital"
  | "ebook";

type CreateProductDataBase = {
  name: string;
  price_currency_type: string;
  price_range: string;
  release_at_date: string;
  release_at_time: string;
  ai_prompt: string | null;
  number_of_content_pages: number | null;
};

type CreateProductDataPhysical = {
  is_recurring_billing: false;
  is_physical: true;
  native_type: "physical";
  subscription_duration: null;
} & CreateProductDataBase;

type CreateProductDataOneTimeDigital = {
  is_recurring_billing: false;
  is_physical: false;
  native_type: OneTimeDigitalProductType;
  subscription_duration: null;
} & CreateProductDataBase;

type CreateProductDataRecurring = {
  is_recurring_billing: true;
  is_physical: false;
  native_type: RecurringProductType;
  subscription_duration: RecurrenceId;
} & CreateProductDataBase;

export type CreateProductData =
  | CreateProductDataPhysical
  | CreateProductDataOneTimeDigital
  | CreateProductDataRecurring;

type CreateProductRequest = {
  link: CreateProductData;
};

type CreateProductResponse =
  | {
      success: true;
      redirect_to: string;
    }
  | {
      success: false;
      error_message: string;
    };

export async function createProduct(requestData: CreateProductRequest) {
  const res = await request({
    method: "POST",
    accept: "json",
    url: Routes.links_path(),
    data: requestData,
  });
  if (!res.ok) throw new ResponseError();
  const jsonResponse = cast<CreateProductResponse>(await res.json());
  return jsonResponse;
}

export function getPagedProducts({
  forArchivedProducts,
  ...params
}: ProductsParams & { forArchivedProducts: boolean }) {
  const abort = new AbortController();

  const url = forArchivedProducts
    ? Routes.products_paged_products_archived_index_path(params)
    : Routes.products_paged_path(params);
  const response = request({
    method: "GET",
    accept: "json",
    url,
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<{ entries: Product[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
}

export function getPagedMemberships({
  forArchivedMemberships,
  ...params
}: MembershipsParams & { forArchivedMemberships: boolean }) {
  const abort = new AbortController();

  const url = forArchivedMemberships
    ? Routes.memberships_paged_products_archived_index_path(params)
    : Routes.memberships_paged_path(params);
  const response = request({
    method: "GET",
    accept: "json",
    url,
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<{ entries: Membership[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
}

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
