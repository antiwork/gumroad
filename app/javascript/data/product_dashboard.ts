import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

export async function deleteProduct(permalink: string) {
  const response = await request({
    method: "DELETE",
    url: Routes.link_path(permalink),
    accept: "json",
  });

  const json = cast<{ success: true } | { success: false; message: string }>(await response.json());
  if (!json.success) throw new ResponseError(json.message);
}

export async function archiveProduct(permalink: string) {
  const response = await request({
    url: Routes.products_archived_index_path(),
    method: "POST",
    accept: "json",
    data: { id: permalink },
  });

  const json = cast<{ success: true } | { success: false; error: string }>(await response.json());
  if (!json.success) throw new ResponseError(json.error || "Failed to archive product");
}

export async function unarchiveProduct(permalink: string) {
  const response = await request({
    url: Routes.products_archived_path(permalink),
    method: "DELETE",
    accept: "json",
  });

  const json = cast<{ success: true; archived_products_count: number } | { success: false; error: string }>(
    await response.json(),
  );
  if (!json.success) throw new ResponseError("Failed to unarchive product");
  return json.archived_products_count;
}

export async function duplicateProduct(permalink: string, productName: string) {
  const response = await request({
    url: Routes.product_duplicates_path(),
    method: "POST",
    accept: "json",
    data: { id: permalink },
  });

  const json = cast<{ success: true } | { success: false; error_message: string }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);

  await pollForProductDuplication(permalink, productName);
}

async function pollForProductDuplication(permalink: string, productName: string) {
  const response = await request({
    url: Routes.product_duplicate_path(permalink),
    method: "GET",
    accept: "json",
  });

  const { status } = cast<{ status: string }>(await response.json());
  if (status === "product_duplication_failed") {
    throw new ResponseError(`Sorry, failed to duplicate '${productName}'. Please try again.`);
  } else if (status === "product_duplicated") {
    return { status };
  }
  await new Promise((resolve) => setTimeout(resolve, 2000));
  return pollForProductDuplication(permalink, productName);
}
