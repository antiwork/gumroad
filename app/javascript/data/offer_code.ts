import typia from "typia";

import { Discount } from "$app/parsers/checkout";
import { CurrencyCode } from "$app/utils/currency";
import { request, ResponseError } from "$app/utils/request";

import { OfferCode, SortKey, Duration } from "$app/components/CheckoutDashboard/DiscountsPage";
import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

type Uid = string;

export type LineItemConfiguration = {
  permalink: string;
  quantity: number;
};
type ComputeDiscountRequestData = {
  code: string;
  products: Record<Uid, LineItemConfiguration>;
};

export const computeOfferDiscount = async (payload: ComputeDiscountRequestData): Promise<OfferCodeResponseData> => {
  try {
    const response = await request({
      method: "GET",
      accept: "json",
      url: Routes.compute_discount_offer_codes_path(payload),
    });
    if (response.ok) {
      return typia.assert<OfferCodeResponseData>(await response.json());
    }
  } catch {}
  return { error_code: "invalid_offer", error_message: "Something went wrong.", valid: false };
};

export type OfferCodeResponseData =
  | {
      valid: false;
      error_code:
        | "sold_out"
        | "invalid_offer"
        | "insufficient_times_of_use"
        | "inactive"
        | "unmet_minimum_purchase_quantity"
        | "not_existing_customer";
      error_message: string;
    }
  | { valid: true; products_data: Record<string, Discount> };

export type ProductOfferCodeSuggestion = {
  id: string;
  code: string;
  name: string;
  discount: Discount;
};

export const searchProductOfferCodes = async (
  productPermalink: string,
  query: string,
): Promise<ProductOfferCodeSuggestion[]> => {
  const params = new URLSearchParams({ query });
  const response = await request({
    method: "GET",
    accept: "json",
    url: `/products/${encodeURIComponent(productPermalink)}/available_offer_codes.json?${params.toString()}`,
  });

  if (!response.ok) throw new ResponseError();

  return typia.assert<ProductOfferCodeSuggestion[]>(await response.json());
};

type DiscountPayload = {
  name: string;
  code: string;
  discount: { type: "cents" | "percent"; value: number };
  selectedProductIds: string[];
  universal: boolean;
  currencyCode: CurrencyCode | null;
  maxQuantity: number | null;
  validAt: string | null;
  expiresAt: string | null;
  minimumQuantity: number | null;
  durationInBillingCycles: Duration | null;
  minimumAmount: number | null;
  existingCustomersOnly: boolean;
  ownershipProductIds: string[];
  ownershipDurationTiers: { months: number; amount_percentage: number }[] | null;
};

export const getPagedDiscounts = (page: number, query: string | null, sort: Sort<SortKey> | null) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.paged_checkout_discounts_path({ page, query, sort }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => typia.assert<{ offer_codes: OfferCode[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

const buildDiscountPayload = (payload: DiscountPayload) => ({
  name: payload.name,
  code: payload.code,
  amount_percentage: payload.discount.type === "percent" ? payload.discount.value : null,
  amount_cents: payload.discount.type === "cents" ? payload.discount.value : null,
  selected_product_ids: payload.universal ? null : payload.selectedProductIds,
  universal: payload.universal,
  max_purchase_count: payload.maxQuantity,
  currency_type: payload.currencyCode,
  valid_at: payload.validAt,
  expires_at: payload.expiresAt,
  minimum_quantity: payload.minimumQuantity,
  duration_in_billing_cycles: payload.durationInBillingCycles,
  minimum_amount_cents: payload.minimumAmount,
  existing_customers_only: payload.existingCustomersOnly,
  ownership_product_ids: payload.existingCustomersOnly ? payload.ownershipProductIds : [],
  ownership_duration_tiers: payload.existingCustomersOnly ? payload.ownershipDurationTiers : null,
});

export const createDiscount = async (payload: DiscountPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_discounts_path(),
    data: buildDiscountPayload(payload),
  });
  const responseData = typia.assert<
    { success: true; offer_codes: OfferCode[]; pagination: PaginationProps } | { success: false; error_message: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return responseData;
};

export const updateDiscount = async (id: string, payload: DiscountPayload) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_discount_path(id),
    data: buildDiscountPayload(payload),
  });
  const responseData = typia.assert<
    { success: true; offer_codes: OfferCode[]; pagination: PaginationProps } | { success: false; error_message: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return responseData;
};

export const deleteDiscount = async (id: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.checkout_discount_path(id),
  });
  const responseData = typia.assert<{ success: true } | { success: false; error_message: string }>(
    await response.json(),
  );
  if (!responseData.success) throw new ResponseError(responseData.error_message);
};

export type OfferCodeStatistics = { uses: { total: number; products: Record<string, number> }; revenue_cents: number };
export const getStatistics = (id: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.statistics_checkout_discount_path(id),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => typia.assert<OfferCodeStatistics>(json));
