import typia from "typia";

import { AbortError, request, ResponseError } from "$app/utils/request";

import { AffiliatedProduct, AffiliatedPageStats, SortKey } from "$app/components/AffiliatedPage";
import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

type PagedAffiliatedProductsData = {
  affiliated_products: AffiliatedProduct[];
  pagination: PaginationProps;
};

// An abort landing after fetch resolved but before the body finished reading rejects with the
// platform DOMException, outside request()'s conversion boundary. Callers only recognize the app's
// own AbortError, so an unconverted one escapes their cancellation branch and strands the loader.
const convertPlatformAbort = (e: unknown): never => {
  if (e instanceof DOMException && e.name === "AbortError") throw new AbortError();
  if (e instanceof AbortError || e instanceof ResponseError) throw e;
  throw new ResponseError();
};

export const getPagedAffiliatedProducts = (page?: number, query?: string, sort?: Sort<SortKey> | null) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.products_affiliated_index_path({ page, query, sort }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json().catch(convertPlatformAbort))
    .then((json) => typia.assert<PagedAffiliatedProductsData>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

// The affiliation is gone already — another tab or window removed it. Distinct from a plain failure
// so the page can say the row is stale and reload the list, rather than inviting a retry that will
// 404 again forever.
export class AffiliationAlreadyRemovedError extends ResponseError {
  constructor() {
    super("This affiliation was already removed. Refreshing your affiliations.");
  }
}

type AffiliationRemovedData = PagedAffiliatedProductsData & { stats: AffiliatedPageStats };

export const removeSelfAsAffiliate = async (
  affiliateId: string,
  { query, sort }: { query?: string; sort?: Sort<SortKey> | null } = {},
): Promise<AffiliationRemovedData> => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.products_affiliated_path(affiliateId, { query, sort }),
  });
  // A stale row 404s with the HTML error page, so parse only once the response is
  // known good — a JSON parse failure here would escape the caller's catch and
  // strand the confirm modal in its in-flight state.
  if (response.status === 404) throw new AffiliationAlreadyRemovedError();
  if (!response.ok) {
    const body = await response.text();
    let message = "Sorry, something went wrong. Please try again.";
    try {
      // A role that may view this page but not remove affiliations gets a 401 naming the role —
      // worth showing rather than replacing with a generic failure.
      message = typia.assert<{ error: string }>(JSON.parse(body)).error;
    } catch {
      /* non-JSON body: keep the generic message */
    }
    throw new ResponseError(message);
  }
  return typia.assert<AffiliationRemovedData>(await response.json());
};
