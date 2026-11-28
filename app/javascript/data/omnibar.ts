import { cast } from "$app/utils/cast";
import { request, ResponseError } from "$app/utils/request";

export type OmnibarProduct = { id: string; name: string; url: string };
export type OmnibarSale = { id: string; email: string; name: string; product_name: string; url: string };

const get = async (group: "products" | "sales", query: string, abortSignal: AbortSignal) => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_omnibar_search_path({ query, group }),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return response;
};

export const searchOmnibarProducts = async (query: string, abortSignal: AbortSignal) =>
  cast<{ products: OmnibarProduct[] }>(await (await get("products", query, abortSignal)).json()).products;

/** Rejects when the sales index could not answer, like any other failed request. */
export const searchOmnibarSales = async (query: string, abortSignal: AbortSignal) => {
  const { sales, sales_unavailable } = cast<{ sales: OmnibarSale[]; sales_unavailable: boolean }>(
    await (await get("sales", query, abortSignal)).json(),
  );
  if (sales_unavailable) throw new ResponseError();
  return sales;
};
