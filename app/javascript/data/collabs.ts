import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

type SortKey = "name" | "successful_sales_count" | "revenue" | "display_price_cents" | "cut";

export type Product = {
  id: number;
  edit_url: string;
  name: string;
  permalink: string;
  successful_sales_count: number;
  remaining_for_sale_count: number | null;
  display_price_cents: number;
  revenue: number;
  price_formatted: string;
  thumbnail: { url: string } | null;
  url: string;
  url_without_protocol: string;
  cut: number;
  can_edit: boolean;
};

export type Membership = Product & {
  has_duration: boolean;
  monthly_recurring_revenue: number;
  revenue_pending: number;
};

export type ProductsParams = {
  page: number | null;
  query: string | null;
  sort?: Sort<SortKey>;
};

export function getPagedProducts(params: MembershipsParams) {
  const abort = new AbortController();

  const url = Routes.products_paged_products_collabs_path(params);
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

export type MembershipsParams = {
  page: number | null;
  query: string | null;
  sort?: Sort<SortKey>;
};

export function getPagedMemberships(params: MembershipsParams) {
  const abort = new AbortController();

  const url = Routes.memberships_paged_products_collabs_path(params);
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
