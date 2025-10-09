import { cast } from "ts-safe-cast";

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
      return cast<OfferCodeResponseData>(await response.json());
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
        | "unmet_minimum_purchase_quantity";
      error_message: string;
    }
  | { valid: true; products_data: Record<string, Discount> };

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
    .then((json) => cast<{ offer_codes: OfferCode[]; pagination: PaginationProps }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

export const createDiscount = async ({
  name,
  code,
  discount,
  selectedProductIds,
  universal,
  currencyCode,
  maxQuantity,
  validAt,
  expiresAt,
  minimumQuantity,
  durationInBillingCycles,
  minimumAmount,
}: DiscountPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_discounts_path(),
    data: {
      name,
      code,
      amount_percentage: discount.type === "percent" ? discount.value : undefined,
      amount_cents: discount.type === "cents" ? discount.value : undefined,
      selected_product_ids: universal ? null : selectedProductIds,
      universal,
      max_purchase_count: maxQuantity,
      currency_type: currencyCode,
      valid_at: validAt,
      expires_at: expiresAt,
      minimum_quantity: minimumQuantity,
      duration_in_billing_cycles: durationInBillingCycles,
      minimum_amount_cents: minimumAmount,
    },
  });
  const responseData = cast<
    { success: true; offer_codes: OfferCode[]; pagination: PaginationProps } | { success: false; error_message: string }
  >(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
  return responseData;
};

export const updateDiscount = async (
  id: string,
  {
    name,
    code,
    discount,
    selectedProductIds,
    universal,
    currencyCode,
    maxQuantity,
    validAt,
    expiresAt,
    minimumQuantity,
    durationInBillingCycles,
    minimumAmount,
  }: DiscountPayload,
) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_discount_path(id),
    data: {
      name,
      code,
      amount_percentage: discount.type === "percent" ? discount.value : undefined,
      amount_cents: discount.type === "cents" ? discount.value : undefined,
      selected_product_ids: universal ? null : selectedProductIds,
      universal,
      max_purchase_count: maxQuantity,
      currency_type: currencyCode,
      valid_at: validAt,
      expires_at: expiresAt,
      minimum_quantity: minimumQuantity,
      duration_in_billing_cycles: durationInBillingCycles,
      minimum_amount_cents: minimumAmount,
    },
  });
  const responseData = cast<
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
  const responseData = cast<{ success: true } | { success: false; error_message: string }>(await response.json());
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
    .then((json) => cast<OfferCodeStatistics>(json));
