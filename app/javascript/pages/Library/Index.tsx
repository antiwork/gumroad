import { usePage } from "@inertiajs/react";
import React from "react";

import { default as LibraryPage, type LibraryPageProps } from "$app/components/LibraryPage";

const Library = () => {
  const { results, creators, bundles, reviews_page_enabled, following_wishlists_enabled } =
    usePage<LibraryPageProps>().props;

  return (
    <LibraryPage
      results={results}
      creators={creators}
      bundles={bundles}
      reviews_page_enabled={reviews_page_enabled}
      following_wishlists_enabled={following_wishlists_enabled}
    />
  );
};

export default Library;
