import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

import { Bundle, BundleProduct } from "$app/components/BundleEdit/state";

export const saveBundle = async (id: string, bundle: Bundle) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.bundle_path(id),
    data: {
      ...bundle,
      covers: bundle.covers.map(({ id }) => id),
      products: bundle.products.map((bundleProduct, idx) => ({
        product_id: bundleProduct.id,
        variant_id: bundleProduct.variants?.selected_id,
        quantity: bundleProduct.quantity,
        position: idx,
      })),
      installment_plan: bundle.allow_installment_plan ? bundle.installment_plan : undefined,
    },
  });
  if (!response.ok) throw new ResponseError(cast<{ error_message: string }>(await response.json()).error_message);
};

export const searchProducts = (params: { product_id: string; query: string; from: number; all: boolean }) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.products_bundles_path(params),
    abortSignal: abort.signal,
  })
    .then((response) => response.json())
    .then((json) => cast<{ products: BundleProduct[] }>(json).products);
  return { response, cancel: () => abort.abort() };
};

export const updatePurchasesContent = async (id: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.update_purchases_content_bundle_path(id),
  });

  if (!response.ok)
    await response.json().then((json) => {
      throw new ResponseError(cast<{ error: string }>(json).error);
    });
};
