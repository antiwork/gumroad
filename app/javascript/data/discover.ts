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

export async function deleteAutocompleteSearch(data: { query: string }) {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.discover_search_autocomplete_path(data),
  });
  if (!response.ok) throw new ResponseError();
}
