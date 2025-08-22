import { request } from "$app/utils/request";
import { cast } from "ts-safe-cast";

export type DiscountCollection = {
  id: string;
  name: string;
  description: string | null;
  offer_codes_count: number;
  total_uses: number;
  total_revenue_cents: number;
  created_at: string;
  can_update: boolean;
  can_destroy: boolean;
  has_defaults: boolean;
  defaults: {
    discount_type: "percent" | "cents" | null;
    discount_value: number | null;
    max_purchase_count: number | null;
    valid_at: string | null;
    expires_at: string | null;
    minimum_quantity: number | null;
    duration_in_billing_cycles: number | null;
    minimum_amount_cents: number | null;
  };
};

export type SortKey = "name" | "created_at" | "offer_codes_count";

export type Sort<T> = {
  key: T;
  direction: "asc" | "desc";
};

export type PaginationProps = {
  page: number;
  pages: number;
  count: number;
  items: number;
};

export type DiscountCollectionResponseData =
  | { valid: false; error_message: string }
  | { valid: true; discount_collections: DiscountCollection[]; pagination: PaginationProps };

type DiscountCollectionPayload = {
  name: string;
  description?: string;
  default_discount_type?: "percent" | "cents";
  default_discount_value?: number;
  default_max_purchase_count?: number;
  default_valid_at?: string | null;
  default_expires_at?: string | null;
  default_minimum_quantity?: number | null;
  default_duration_in_billing_cycles?: number | null;
  default_minimum_amount_cents?: number | null;
};

type BulkCreateCodesPayload = {
  count: number;
  name_template: string;
  discount: { type: "cents" | "percent"; value: number };
  selectedProductIds: string[];
  universal: boolean;
  max_purchase_count: number | null;
  valid_at: string | null;
  expires_at: string | null;
  minimum_quantity: number | null;
  duration_in_billing_cycles: number | null;
  minimum_amount_cents: number | null;
};

export const getPagedDiscountCollections = (page: number, query: string | null, sort: Sort<SortKey> | null) => {
  const abort = new AbortController();
  const searchParams = new URLSearchParams();

  if (page > 1) searchParams.set("page", page.toString());
  if (query) searchParams.set("query", query);
  if (sort) {
    searchParams.set("sort[key]", sort.key);
    searchParams.set("sort[direction]", sort.direction);
  }

  const response = request({
    method: "GET",
    accept: "json",
    url: `${Routes.checkout_discount_collections_path()}?${searchParams.toString()}`,
    abortSignal: abort.signal,
  });

  return {
    response,
    cancel: () => abort.abort(),
  };
};

export const createDiscountCollection = async ({
  name,
  description,
}: DiscountCollectionPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.checkout_discount_collections_path(),
    data: {
      name,
      description,
    },
  });

  const responseData = cast<
    { success: true; discount_collections: DiscountCollection[]; pagination: PaginationProps } | { success: false; error_message: string }
  >(await response.json());

  if (!responseData.success) throw new Error(responseData.error_message);
  return responseData;
};

export const updateDiscountCollection = async (
  id: string,
  { name, description }: DiscountCollectionPayload
) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.checkout_discount_collection_path(id),
    data: {
      name,
      description,
    },
  });

  const responseData = cast<
    { success: true; discount_collections: DiscountCollection[]; pagination: PaginationProps } | { success: false; error_message: string }
  >(await response.json());

  if (!responseData.success) throw new Error(responseData.error_message);
  return responseData;
};

export const deleteDiscountCollection = async (id: string, deleteCodes: boolean = false) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.checkout_discount_collection_path(id),
    data: {
      delete_codes: deleteCodes,
    },
  });

  const responseData = cast<{ success: boolean; error_message?: string }>(await response.json());

  if (!responseData.success) throw new Error(responseData.error_message || "Failed to delete discount collection");
  return responseData;
};

        export const bulkCreateCodes = async (
          collectionId: string,
          payload: BulkCreateCodesPayload
        ) => {
          const response = await request({
            method: "POST",
            accept: "json",
            url: Routes.bulk_create_codes_checkout_discount_collection_path(collectionId),
            data: {
              count: payload.count,
              name_template: payload.name_template,
              discount: payload.discount,
              selected_product_ids: payload.universal ? null : payload.selectedProductIds,
              universal: payload.universal,
              max_purchase_count: payload.max_purchase_count,
              valid_at: payload.valid_at,
              expires_at: payload.expires_at,
              minimum_quantity: payload.minimum_quantity,
              duration_in_billing_cycles: payload.duration_in_billing_cycles,
              minimum_amount_cents: payload.minimum_amount_cents,
            },
          });

          const responseData = cast<
            { success: true; message: string; created_count: number } | { success: false; error_message: string; failed_codes?: { name: string; error: string }[] }
          >(await response.json());

          if (!responseData.success) throw new Error(responseData.error_message);
          return responseData;
        };

        export const quickCreateCode = async (
          collectionId: string,
          name?: string
        ) => {
          const response = await request({
            method: "POST",
            accept: "json",
            url: Routes.quick_create_code_checkout_discount_collection_path(collectionId),
            data: { name },
          });

          const responseData = cast<
            { success: true; message: string; offer_code: { id: string; name: string; code: string; url: string } } | { success: false; error_message: string }
          >(await response.json());

          if (!responseData.success) throw new Error(responseData.error_message);
          return responseData;
        };

        export const exportCollectionCsv = async (collectionId: string) => {
          const response = await request({
            method: "GET",
            accept: "csv",
            url: Routes.export_csv_checkout_discount_collection_path(collectionId),
          });

          return response.text();
        };
