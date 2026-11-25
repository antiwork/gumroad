import { cast } from "$app/utils/cast";
import { request, ResponseError } from "$app/utils/request";

export type OmnibarProduct = { id: string; name: string; url: string };
export type OmnibarCustomer = { id: string; email: string; name: string; product_name: string; url: string };
export type OmnibarSearchResults = {
  products: OmnibarProduct[];
  customers: OmnibarCustomer[];
  customers_unavailable: boolean;
};

export const searchOmnibar = async (query: string, abortSignal: AbortSignal) => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_omnibar_search_path({ query }),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return cast<OmnibarSearchResults>(await response.json());
};
