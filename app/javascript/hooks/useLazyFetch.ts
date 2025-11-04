import React from "react";
import { cast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";

interface UseLazyFetchOptions<T> {
  url: string;
  responseParser: (data: unknown) => T;
  fetchUnlessLoaded: boolean;
}

interface UseLazyFetchResult<T> {
  data: T;
  isLoading: boolean;
  setIsLoading: (isLoading: boolean) => void;
  setData: (data: T) => void;
  fetchData: (queryParams?: QueryParams) => Promise<void>;
  hasLoaded: boolean;
  setHasLoaded: (hasLoaded: boolean) => void;
}

type QueryParams = Record<string, string | number>;

export type Pagination = {
  count?: number;
  next?: number | null;
  page: number;
  limit: number;
};

type PaginatedResponse = {
  pagination: Pagination;
};

// Internal hook that handles the core fetching logic
const useLazyFetchCore = <T>(
  initialData: T,
  options: UseLazyFetchOptions<T>,
  onSuccess?: (responseData: unknown, parsedData: T) => void,
) => {
  const [data, setData] = React.useState<T>(initialData);
  const [isLoading, setIsLoading] = React.useState(true);
  const [hasLoaded, setHasLoaded] = React.useState(false);

  const fetchData = React.useCallback(
    async (queryParams: QueryParams = {}) => {
      setIsLoading(true);

      try {
        const url = new URL(options.url, window.location.origin);
        Object.entries(queryParams).forEach(([key, value]) => {
          url.searchParams.set(key, value.toString());
        });

        const response = await request({
          method: "GET",
          accept: "json",
          url: url.pathname + url.search,
        });
        const responseData: unknown = await response.json();
        const parsedData = options.responseParser(responseData);

        setData(parsedData);
        setHasLoaded(true);

        onSuccess?.(responseData, parsedData);
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      } finally {
        setIsLoading(false);
      }
    },
    [options.url, options.responseParser, onSuccess],
  );

  return {
    data,
    setData,
    isLoading,
    setIsLoading,
    fetchData,
    hasLoaded,
    setHasLoaded,
  };
};

const useFetchOnMount = (
  options: { fetchUnlessLoaded?: boolean },
  hasLoaded: boolean,
  fetchFn: () => Promise<void>,
) => {
  const fetchUnlessLoaded = options.fetchUnlessLoaded ?? true;

  React.useEffect(() => {
    if (fetchUnlessLoaded && !hasLoaded) {
      void fetchFn();
    }
  }, [fetchUnlessLoaded, hasLoaded, fetchFn]);
};

export const useLazyFetch = <T>(initialData: T, options: UseLazyFetchOptions<T>): UseLazyFetchResult<T> => {
  const core = useLazyFetchCore(initialData, options);

  useFetchOnMount(options, core.hasLoaded, core.fetchData);

  return core;
};

type UseLazyPaginatedFetchResult<T> = UseLazyFetchResult<T> & {
  hasMore: boolean;
  setHasMore: (hasMore: boolean) => void;
  pagination: Pagination;
  fetchNextPage: () => Promise<void>;
};

interface UseLazyPaginatedFetchOptions<T> extends UseLazyFetchOptions<T> {
  mode?: "append" | "prepend" | "replace";
  perPage?: number;
}

function mergeArrayData<T>(prev: T, next: T, mode: "append" | "prepend"): T {
  if (!Array.isArray(prev) || !Array.isArray(next)) {
    return next;
  }

  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
  return (mode === "append" ? [...prev, ...next] : [...next, ...prev]) as T;
}

export const useLazyPaginatedFetch = <T extends unknown[]>(
  initialData: T,
  options: UseLazyPaginatedFetchOptions<T>,
): UseLazyPaginatedFetchResult<T> => {
  const mode = options.mode ?? "append";
  const perPage = options.perPage ?? 20;

  const [hasMore, setHasMore] = React.useState(false);
  const [pagination, setPagination] = React.useState<Pagination>({
    count: 0,
    next: null,
    page: 0,
    limit: 0,
  });
  const [currentData, setCurrentData] = React.useState<T>(initialData);
  const core = useLazyFetchCore(initialData, options, (responseData, parsedData) => {
    const { pagination: paginationData } = cast<PaginatedResponse>(responseData);
    setPagination(paginationData);

    const canFetchMore =
      "next" in paginationData ? paginationData.next !== null : parsedData.length === paginationData.limit;
    setHasMore(canFetchMore);

    if (mode === "replace") {
      setCurrentData(parsedData);
      return;
    }

    setCurrentData((prev) => mergeArrayData(prev, parsedData, mode));
  });

  const fetchData = React.useCallback(
    (queryParams: QueryParams = {}): Promise<void> => core.fetchData({ ...queryParams, per_page: perPage }),
    [core.fetchData, perPage],
  );

  useFetchOnMount(options, core.hasLoaded, fetchData);

  const fetchNextPage = React.useCallback((): Promise<void> => {
    if (!hasMore) {
      return Promise.resolve();
    }
    return fetchData({ page: pagination.next ?? pagination.page + 1 });
  }, [hasMore, pagination.next, fetchData]);

  return {
    ...core,
    data: currentData,
    setData: setCurrentData,
    hasMore,
    setHasMore,
    pagination,
    fetchData,
    fetchNextPage,
  };
};
