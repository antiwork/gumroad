import { router } from "@inertiajs/react";
import React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

export const useProductsSearch = () => {
  const urlParams = new URLSearchParams(window.location.search);
  const initialQuery = urlParams.get("query") || "";
  const [query, setQuery] = React.useState(initialQuery);

  const debouncedSearch = useDebouncedCallback((searchQuery: string) => {
    router.reload({
      data: {
        query: searchQuery || undefined,
        products_page: undefined,
        memberships_page: undefined,
      },
      only: ["products_data", "memberships_data", "has_products"],
      reset: ["products_data", "memberships_data"],
    });
  }, 300);

  useOnChange(() => debouncedSearch(query), [query]);

  return { query, setQuery };
};
