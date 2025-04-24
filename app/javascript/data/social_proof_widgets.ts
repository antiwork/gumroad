import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";
import { SocialProofWidget, SortKey } from "$app/components/server-components/CheckoutDashboard/SocialProofWidgetsPage";
import { Sort } from "$app/components/useSortingTableDriver";

export type SocialProofWidgetPayload = {
  name: string;
  title: string;
  description: string;
  universal: boolean;
  published: boolean;
  iconColor?: string;
  ctaText: string;
  ctaType: string;
  imageType: string;
  customImageSignedId?: string;
  productIds: string[];
};

export const getPagedSocialProofWidgets = (page: number, query: string | null, sort: Sort<SortKey> | null) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.paged_checkout_social_proof_widgets_path({ page, query, sort }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<{ social_proof_widgets: SocialProofWidget[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};
