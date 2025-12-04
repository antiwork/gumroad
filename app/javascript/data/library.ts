import { request, ResponseError } from "$app/utils/request";

export async function deletePurchasedProduct(data: { purchase_id: string }) {
  const url = Routes.library_delete_path(data.purchase_id);
  const response = await request({ url, method: "PATCH", accept: "json" });
  if (!response.ok) throw new ResponseError();
}
