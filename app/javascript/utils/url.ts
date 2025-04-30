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
