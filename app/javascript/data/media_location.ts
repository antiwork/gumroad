import { request } from "$app/utils/request";

export const trackMediaLocationChanged = async ({
  urlRedirectId,
  productFileId,
  purchaseId,
  location,
}: {
  urlRedirectId: string;
  productFileId: string;
  purchaseId: string;
  location: number;
}) => {
  await request({
    method: "POST",
    url: Routes.media_locations_path({ format: "json" }),
    accept: "json",
    data: {
      platform: "web",
      url_redirect_id: urlRedirectId,
      product_file_id: productFileId,
      purchase_id: purchaseId,
      location,
      consumed_at: new Date().toISOString(),
    },
  });
};
