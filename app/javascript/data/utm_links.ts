import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

// Types re-exported from types/utm_link.ts for backward compatibility
export type {
  UtmLinkDestinationOption,
  UtmLink,
  SavedUtmLink,
  UtmLinkStats,
  UtmLinksStats,
  UtmLinkFormContext,
  UtmLinkRequestPayload,
  SortKey,
} from "$app/types/utm_link";

import type { UtmLinksStats } from "$app/types/utm_link";

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

export async function getUniquePermalink() {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.unique_permalink_utm_links_dashboard_index_path(),
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ permalink: string }>(await response.json());
}
