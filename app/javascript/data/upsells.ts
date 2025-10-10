import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { ProductToAdd } from "$app/components/Checkout/cartState";
import { Upsell, SortKey } from "$app/components/CheckoutDashboard/UpsellsPage";
import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

export type UpsellPayload = {
  name: string;
  text: string;
  description: string;
  isCrossSell: boolean;
  replaceSelectedProducts: boolean;
  universal: boolean;
  productId: string;
  variantId: string | null;
  offerCode: { amount_cents: number } | { amount_percentage: number } | null;
  productIds: string[];
  upsellVariants: { selectedVariantId: string; offeredVariantId: string }[];
  paused: boolean;
};

export const createUpsell = async ({
  name,
  text,
  description,
  isCrossSell,
  replaceSelectedProducts,
  universal,
  productId,
  variantId,
  offerCode,
  productIds,
  upsellVariants,
  paused,
}: UpsellPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_upsells_path(),
    data: {
      name,
      text,
      description,
      cross_sell: isCrossSell,
      replace_selected_products: replaceSelectedProducts,
      universal,
      product_id: productId,
      variant_id: variantId ?? undefined,
      offer_code: offerCode ?? undefined,
      product_ids: productIds,
      upsell_variants: upsellVariants.map(({ selectedVariantId, offeredVariantId }) => ({
        selected_variant_id: selectedVariantId,
        offered_variant_id: offeredVariantId,
      })),
      paused,
    },
  });
  const responseData = cast<
    { success: true; upsells: Upsell[]; pagination: PaginationProps } | { success: false; error: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error);

  return responseData;
};

export const updateUpsell = async (
  id: string,
  {
    name,
    text,
    description,
    isCrossSell,
    replaceSelectedProducts,
    universal,
    productId,
    variantId,
    offerCode,
    productIds,
    upsellVariants,
    paused,
  }: UpsellPayload,
) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_upsell_path(id),
    data: {
      name,
      text,
      description,
      cross_sell: isCrossSell,
      replace_selected_products: replaceSelectedProducts,
      universal,
      product_id: productId,
      variant_id: variantId ?? undefined,
      offer_code: offerCode ?? undefined,
      product_ids: productIds,
      upsell_variants: upsellVariants.map(({ selectedVariantId, offeredVariantId }) => ({
        selected_variant_id: selectedVariantId,
        offered_variant_id: offeredVariantId,
      })),
      paused,
    },
  });
  const responseData = cast<
    { success: true; upsells: Upsell[]; pagination: PaginationProps } | { success: false; error: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error);

  return responseData;
};

export const deleteUpsell = async (id: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.checkout_upsell_path(id),
  });
  const responseData = cast<
    { success: true; upsells: Upsell[]; pagination: PaginationProps } | { success: false; error: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error);

  return responseData;
};

export const pauseUpsell = async (id: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_upsell_pause_path(id),
  });
  if (!response.ok) throw new ResponseError();
};

export const resumeUpsell = async (id: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.checkout_upsell_pause_path(id),
  });
  if (!response.ok) throw new ResponseError();
};

export const getPagedUpsells = (page: number, query: string | null, sort: Sort<SortKey> | null) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.paged_checkout_upsells_path({ page, query, sort }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<{ upsells: Upsell[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

export type UpsellStatistics = {
  uses: { total: number; selected_products: Record<string, number>; upsell_variants: Record<string, number> };
  revenue_cents: number;
};
export const getStatistics = (id: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.statistics_checkout_upsell_path(id),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<UpsellStatistics>(json));

export const getCartItem = (productId: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.cart_item_checkout_upsells_path({ product_id: productId }),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<ProductToAdd>(json));
