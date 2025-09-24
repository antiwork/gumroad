import { usePage } from "@inertiajs/react";
import React from "react";

import { default as LibraryPage, type LibraryPageProps } from "$app/components/server-components/LibraryPage";

const Library = () => {
  const { library_page_props } = usePage<{ library_page_props: LibraryPageProps }>().props;

  return <LibraryPage {...library_page_props} />;
};

export default Library;
