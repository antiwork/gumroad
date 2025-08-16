export const isUrlValid = (url: string): boolean => {
  try {
    const newUrl = new URL(url);
    return newUrl.protocol === "http:" || newUrl.protocol === "https:";
  } catch {
    return false;
  }
};

export const writeQueryParams = (url: URL, values: Record<string, string | null>): URL => {
  for (const [key, value] of Object.entries(values))
    if (value) url.searchParams.set(key, value);
    else url.searchParams.delete(key);
  url.searchParams.sort();
  return url;
};

export const paramsToQueryString = (params: Record<string, string | string[] | undefined>) =>
  Object.keys(params)
    .map((key) => {
      const value = params[key];
      return Array.isArray(value)
        ? value.map((v) => `${key}[]=${encodeURIComponent(v)}`).join("&")
        : `${key}=${encodeURIComponent(value ?? "")}`;
    })
    .join("&");

export const extractParams = (searchParams: URLSearchParams) => {
  const query = searchParams.get("query");
  const pageStr = searchParams.get("page");
  const page = pageStr ? parseInt(pageStr, 10) : 1;
  
  const sortKey = searchParams.get("sort[key]");
  const sortDirection = searchParams.get("sort[direction]");
  const sort = sortKey && sortDirection ? { key: sortKey, direction: sortDirection as "asc" | "desc" } : null;
  
  return {
    query: query ? decodeURIComponent(query) : null,
    sort,
    page,
  };
};

export const setUrlQueryParams = (params: { query?: string | null; sort?: { key: string; direction: string } | null; page?: number | null }) => {
  const currentUrl = new URL(window.location.href);
  const newUrl = writeQueryParams(currentUrl, {
    page: params.page?.toString() || null,
    query: params.query || null,
    "sort[key]": params.sort?.key || null,
    "sort[direction]": params.sort?.direction || null,
  });
  if (newUrl.toString() !== window.location.href) {
    window.history.pushState(params, document.title, newUrl.toString());
  }
};
