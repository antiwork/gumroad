import * as React from "react";
import { PaginationProps } from "$app/components/Pagination";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useApiErrorHandler } from "./useApiErrorHandler";
import { Sort } from "$app/components/useSortingTableDriver";

type PagedTableState<T> = {
  entries: readonly T[];
  pagination: PaginationProps;
  isLoading: boolean;
};

type FetchParams<S> = {
  page: number;
  query: string | null;
  sort: Sort<S> | null;
  [key: string]: any;
};

type FetchFunction<T, S> = (params: FetchParams<S>) => {
  response: Promise<{ entries: T[]; pagination: PaginationProps }>;
  cancel: () => void;
};

export const usePagedTableData = <T, S>(
  fetchFunction: FetchFunction<T, S>,
  initialEntries: T[],
  initialPagination: PaginationProps,
  query: string | null,
  sort: Sort<S> | null,
  additionalParams: Record<string, any> = {}
) => {
  const [{ entries, pagination, isLoading }, setState] = React.useState<PagedTableState<T>>({
    entries: initialEntries,
    pagination: initialPagination,
    isLoading: false,
  });

  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const tableRef = React.useRef<HTMLTableElement>(null);
  const handleError = useApiErrorHandler();

  const loadData = React.useCallback(async (page: number) => {
    setState((prevState) => ({ ...prevState, isLoading: true }));
    try {
      activeRequest.current?.cancel();

      const request = fetchFunction({
        page,
        query,
        sort,
        ...additionalParams,
      });
      activeRequest.current = request;

      const response = await request.response;
      setState((prevState) => ({
        ...prevState,
        ...response,
        isLoading: false,
      }));
      activeRequest.current = null;
      tableRef.current?.scrollIntoView({ behavior: "smooth" });
    } catch (e) {
      handleError(e, (loading) => 
        setState((prevState) => ({ ...prevState, isLoading: loading }))
      );
    }
  }, [fetchFunction, query, sort, additionalParams, handleError]);

  const debouncedLoadData = useDebouncedCallback(() => void loadData(1), 300);

  React.useEffect(() => {
    if (sort) void loadData(1);
  }, [sort, loadData]);

  React.useEffect(() => {
    if (query !== null) debouncedLoadData();
  }, [query, debouncedLoadData]);

  const reloadData = React.useCallback(() => loadData(pagination.page), [loadData, pagination.page]);

  return {
    entries,
    pagination,
    isLoading,
    tableRef,
    loadData,
    reloadData,
  };
};