import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import type { PaginationProps } from "$app/components/Pagination";

type SocialProofPayload = {
  name: string;
  titleText: string;
  description: string;
  ctaText: string;
  ctaType: { id: "button" | "link" | "none"; label: string };
  image: { id: "product_thumbnail" | "custom_image" | "icon" | "none"; label: string };
  icon: string;
  iconColor: string;
  selectedProductIds: string[];
  universal: boolean;
  status: string;
  visibility: "all" | "new" | "returning";
};

export type SocialProofWidget = {
  id: number;
  name: string;
  universal: boolean;
  title: string;
  description: string;
  cta_text: string;
  cta_type: string;
  image_type: string;
  image_url: string | null;
  icon_name: IconName;
  icon_color: string;
  published: boolean;
  visibility: "all" | "new" | "returning";
  product_ids: string[];
  can_update: boolean;
  clicks: number;
  conversion_rate: string;
  revenue: string;
  status: string;
};

export type Sort<T extends string> = {
  key: T;
  direction: "asc" | "desc";
};

export const createSocialProof = async (payload: SocialProofPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: "/checkout/social",
    data: payload,
  });

  return response;
};

export const updateSocialProof = async (id: number, payload: SocialProofPayload) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: `/checkout/social/${id}`,
    data: payload,
  });

  return response;
};

export const deleteSocialProof = async (id: number) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: `/checkout/social/${id}`,
  });

  return response;
};

export const trackSocialProofEvent = async (
  widgetId: number,
  eventType: "impression" | "click" | "purchase",
  options: {
    purchaseId?: number;
    revenueCents?: number;
  } = {},
) => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: "/social_proof/track_event",
      data: {
        widget_id: widgetId,
        event_type: eventType,
        purchase_id: options.purchaseId,
        revenue_cents: options.revenueCents,
      },
    });

    return response;
  } catch (error) {
    return null;
  }
};

export const getPagedSocialProofWidgets = (
  page: number,
  query: string | null,
  sort: Sort<"name" | "clicks" | "conversion" | "revenue" | "status"> | null,
) => {
  const abort = new AbortController();
  const params = new URLSearchParams();
  params.append("page", page.toString());
  if (query) params.append("query", query);
  if (sort?.direction) params.append("sort", sort.direction);
  if (sort?.key) params.append("column", sort.key);

  const response = request({
    method: "GET",
    accept: "json",
    url: `/checkout/social/paged?${params.toString()}`,
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<{ social_proof_widgets: SocialProofWidget[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};
