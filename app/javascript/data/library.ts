import { request, ResponseError } from "$app/utils/request";

export async function setPurchaseArchived(data: { purchase_id: string; is_archived: boolean }) {
  const url = data.is_archived
    ? Routes.library_archive_path(data.purchase_id)
    : Routes.library_unarchive_path(data.purchase_id);
  const response = await request({ url, method: "PATCH", accept: "json" });
  if (!response.ok) throw new ResponseError();
}

export async function deletePurchasedProduct(data: { purchase_id: string }) {
  const url = Routes.library_delete_path(data.purchase_id);
  const response = await request({ url, method: "PATCH", accept: "json" });
  if (!response.ok) throw new ResponseError();
}
