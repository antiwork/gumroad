import typia from "typia";

import { CardProduct } from "$app/parsers/product";
import { request } from "$app/utils/request";

type SearchRequestType = {
  from: number;
  tags: string[];
  filetypes: string[];
  offer_code: string;
  sort: string;
  min_price: number;
  max_price: number;
  rating: number;
  user_id: string;
  section_id: string;
  exclude_ids: string[];
  recommended_by: string;
  query: string;
  taxonomy: string;
  curated_product_ids: string[];
  taxonomy_attribute_filters: string[];
};
export type SearchRequest = { [key in keyof SearchRequestType]?: SearchRequestType[key] | undefined };

export type ProductFilter = { key: string; doc_count: number; label?: string };
export type TaxonomyAttributeFilterGroup = { name: string; label: string; filters: ProductFilter[] };

export type SearchResults = {
  products: CardProduct[];
  filetypes_data: ProductFilter[];
  tags_data: ProductFilter[];
  taxonomy_attributes_data: TaxonomyAttributeFilterGroup[];
  total: number;
};

export function getSearchResults(data: SearchRequest): { response: Promise<SearchResults>; cancel(): void } {
  const abort = new AbortController();
  const promise = request({
    method: "GET",
    abortSignal: abort.signal,
    url: Routes.products_search_path(data),
    accept: "json",
  })
    .then((res) => res.json())
    .then((json) => typia.assert<SearchResults>(json));
  return { response: promise, cancel: () => abort.abort() };
}
