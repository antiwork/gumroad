import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { type PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";
import type {
  UtmLinkDestinationOption,
  UtmLink,
  SavedUtmLink,
  UtmLinkStats,
  UtmLinksStats,
  UtmLinkFormContext,
  UtmLinkRequestPayload,
  SortKey,
} from "$app/types/utm_link";

// Re-export types for backwards compatibility
export type {
  UtmLinkDestinationOption,
  UtmLink,
  SavedUtmLink,
  UtmLinkStats,
  UtmLinksStats,
  UtmLinkFormContext,
  UtmLinkRequestPayload,
  SortKey,
};

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
