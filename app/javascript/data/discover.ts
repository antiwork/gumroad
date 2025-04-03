import { cast } from "ts-safe-cast";

import { CardProduct } from "$app/parsers/product";
import { request, ResponseError } from "$app/utils/request";

export type AutocompleteSearchResults = {
  products: {
    name: string;
    url: string;
    seller_name: string | null;
    thumbnail_url: string | null;
  }[];
  recent_searches: string[];
  viewed?: boolean;
};

export async function getAutocompleteSearchResults(data: { query: string }, abortSignal?: AbortSignal) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.discover_search_autocomplete_path(data),
    abortSignal,
  });
  if (!response.ok) throw new ResponseError();
  return cast<AutocompleteSearchResults>(await response.json());
}

export async function deleteAutocompleteSearch(data: { query: string }) {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.discover_search_autocomplete_path(data),
  });
  if (!response.ok) throw new ResponseError();
}

export async function getRecommendedProducts(data: { taxonomy: string | undefined }) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.discover_recommended_products_path(data),
  });
  if (!response.ok) throw new ResponseError();
  return cast<CardProduct[]>(await response.json());
}
