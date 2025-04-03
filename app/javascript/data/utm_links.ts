import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { type PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

export type UtmLinkDestinationOption = {
  id: string;
  label: string;
  url: string;
};

export type UtmLink = {
  id?: string;
  destination_option?: UtmLinkDestinationOption;
  title: string;
  short_url: string;
  utm_url: string;
  created_at: string;
  source: string;
  medium: string;
  campaign: string;
  term: string | null;
  content: string | null;
  clicks: number;
  sales_count: number | null;
  revenue_cents: number | null;
  conversion_rate: number | null;
};

export type SavedUtmLink = UtmLink & {
  id: string;
};

export type UtmLinkStats = {
  sales_count: number | null;
  revenue_cents: number | null;
  conversion_rate: number | null;
};

export type UtmLinksStats = Record<string, UtmLinkStats>;

export type UtmLinkFormContext = {
  destination_options: UtmLinkDestinationOption[];
  short_url: string;
  utm_fields_values: {
    campaigns: string[];
    mediums: string[];
    sources: string[];
    terms: string[];
    contents: string[];
  };
};

export type UtmLinkRequestPayload = {
  title: string;
  target_resource_type: string;
  target_resource_id: string | null;
  permalink: string;
  utm_source: string;
  utm_medium: string;
  utm_campaign: string;
  utm_term: string | null;
  utm_content: string | null;
};

export type SortKey =
  | "link"
  | "date"
  | "source"
  | "medium"
  | "campaign"
  | "clicks"
  | "sales_count"
  | "revenue_cents"
  | "conversion_rate";

export async function getUtmLinks({
  query,
  page,
  sort,
  abortSignal,
}: {
  query: string | null;
  page: number | null;
  sort: Sort<SortKey> | null;
  abortSignal: AbortSignal;
}) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_utm_links_path({ query, page, sort }),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return cast<{
    utm_links: SavedUtmLink[];
    pagination: PaginationProps;
  }>(await response.json());
}

export function getUtmLinksStats({ ids }: { ids: string[] }) {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.internal_utm_links_stats_path({ ids }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<UtmLinksStats>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
}

export async function getNewUtmLink({ abortSignal, copyFrom }: { abortSignal: AbortSignal; copyFrom: string | null }) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.new_internal_utm_link_path({ copy_from: copyFrom }),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ context: UtmLinkFormContext; utm_link: UtmLink | null }>(await response.json());
}

export async function getEditUtmLink({ id, abortSignal }: { id: string; abortSignal: AbortSignal }) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.edit_internal_utm_link_path(id),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ context: UtmLinkFormContext; utm_link: SavedUtmLink }>(await response.json());
}

export async function getUniquePermalink() {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_utm_link_unique_permalink_path(),
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ permalink: string }>(await response.json());
}

export async function createUtmLink(data: UtmLinkRequestPayload) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_utm_links_path(),
    data,
  });
  if (!response.ok) {
    const error = cast<{ error: string; attr_name: string | null }>(await response.json());
    throw new ResponseError(JSON.stringify(error));
  }
}

export async function updateUtmLink(id: string, data: UtmLinkRequestPayload) {
  const response = await request({
    method: "PATCH",
    accept: "json",
    url: Routes.internal_utm_link_path({ id }),
    data,
  });
  if (!response.ok) throw new ResponseError();
}

export async function deleteUtmLink(id: string) {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.internal_utm_link_path({ id }),
  });
  if (!response.ok) throw new ResponseError();
}
