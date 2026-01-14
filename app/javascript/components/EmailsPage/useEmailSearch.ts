import { router } from "@inertiajs/react";
import React from "react";

import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

/**
 * Custom hook for email search functionality.
 * Handles URL query parameter, state management, and debounced search.
 */
export const useEmailSearch = () => {
  const urlParams = new URLSearchParams(window.location.search);
  const initialQuery = urlParams.get("query") || "";
  const [query, setQuery] = React.useState(initialQuery);

  const debouncedSearch = useDebouncedCallback((searchQuery: string) => {
    router.reload({
      data: { query: searchQuery || undefined, page: undefined },
      only: ["installments", "pagination", "has_posts"],
      reset: ["installments"],
    });
  }, 500);

  useOnChange(() => debouncedSearch(query), [query]);

  return { query, setQuery };
};
