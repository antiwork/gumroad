import { request } from "$app/utils/request";

export async function fetchProductViewsCount(productId: string) {
  const response = await request({
    method: "GET",
    url: Routes.views_count_admin_product_path(productId),
    accept: "html",
  });
  if (!response.ok) throw new Error("Server returned error response");
  return response.text();
}

export async function fetchProductSalesStats(productId: string) {
  const response = await request({
    method: "GET",
    url: Routes.sales_stats_admin_product_path(productId),
    accept: "html",
  });
  if (!response.ok) throw new Error("Server returned error response");
  return response.text();
}
