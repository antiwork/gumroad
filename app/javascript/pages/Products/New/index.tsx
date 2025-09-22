import { usePage } from "@inertiajs/react";
import React from "react";

import { default as NewProductPage, NewProductPageProps } from "$app/components/server-components/NewProductPage";

function New() {
  const { new_product_page_props } = usePage<{ new_product_page_props: NewProductPageProps }>().props;

  return <NewProductPage {...new_product_page_props} />;
}

export default New;
