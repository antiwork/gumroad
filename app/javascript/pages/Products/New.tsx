import { usePage } from "@inertiajs/react";
import React from "react";

import { default as NewProductPage, type NewProductPageProps } from "$app/components/NewProductPage";

function New() {
  const props = usePage<NewProductPageProps>().props;

  return <NewProductPage {...props} />;
}

export default New;
