import { request } from "$app/utils/request";

export const createConsumptionEvent = async (data: {
  eventType: string;
  urlRedirectId: string;
  productFileId: string;
  purchaseId: string | null;
}) => {
  await request({
    method: "POST",
    url: Routes.consumption_analytics_path({ format: "json" }),
    accept: "json",
    data: {
      event_type: data.eventType,
      platform: "web",
      url_redirect_id: data.urlRedirectId,
      product_file_id: data.productFileId,
      purchase_id: data.purchaseId,
    },
  });
};
