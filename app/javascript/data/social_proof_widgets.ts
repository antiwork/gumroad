import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";

export type Widget = {
  id: string;
  name: string;
  title: string;
  description: string;
  universal: boolean;
  cta_type: string;
  image_type: string;
  status: "published" | "unpublished";
  product_count: number;
  products: Array<{
    id: string;
    name: string;
  }>;
  created_at: string;
  updated_at: string;
  icon_color: string | null;
  impressions_count: number;
  clicks_count: number;
  dismissals_count: number;
  conversions_count: number;
  conversion_rate: number;
  revenue_cents: number;
};

export type SortKey = "name" | "updated_at" | "status";

export type SocialProofWidgetPayload = {
  name: string;
  universal: boolean;
  title: string;
  description: string;
  cta_text: string;
  cta_type: "button" | "link" | "none";
  image_type: string;
  status: "published" | "unpublished";
  product_ids: string[];
  custom_image_signed_blob_id?: string | null;
  icon_color: string | null;
};

export type SocialWidgetEditProps = {
  title?: string;
  description?: string;
  cta_text?: string;
  cta_type: "button" | "link" | "none";
  image_type?: string;
  product_ids?: string[];
  custom_image_url?: string | null;
  status: "published" | "unpublished";
};

export const getPagedSocialProofWidgets = (params: { query?: string; page?: number }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.paged_checkout_social_proof_widgets_path(params),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<{ widgets: Widget[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

export const createSocialProofWidget = async (payload: SocialProofWidgetPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_social_proof_widgets_path(),
    data: { social_proof_widget: payload },
  });
  const responseData = cast<
    { success: true; widget: Widget } | { success: false; error_message: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return responseData;
};

export const updateSocialProofWidget = async (id: string, payload: SocialProofWidgetPayload) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_social_proof_widget_path(id),
    data: { social_proof_widget: payload },
  });
  const responseData = cast<
    { success: true; widget: Widget } | { success: false; error_message: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return responseData;
};

export const deleteSocialProofWidget = async (id: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.checkout_social_proof_widget_path(id),
  });
  const responseData = cast<{ success: true } | { success: false; error_message: string }>(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
};

export const getSocialProofWidget = async (id: string) => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.checkout_social_proof_widget_path(id),
  });
  return cast<SocialWidgetEditProps>(await response.json());
};

export const trackWidgetImpression = async (widgetId: string) => {
  await request({
    method: 'POST',
    url: `/products/social_proof_widgets/impression?widget_id=${widgetId}`,
    accept: 'json'
  });
};

export const trackWidgetClick = async (widgetId: string) => {
  await request({
    method: "POST", 
    url: `/products/social_proof_widgets/click?widget_id=${widgetId}`,
    accept: "json",
  });
};

export const trackWidgetDismiss = async (widgetId: string) => {
  await request({
    method: "POST",
    url: `/products/social_proof_widgets/dismiss?widget_id=${widgetId}`,
    accept: "json",
  });
};