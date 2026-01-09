import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { ProductEditPage, type Props } from "$app/components/server-components/ProductEditPage";

export default function ProductsEdit() {
  const props = cast<Props>(usePage().props);
  return <ProductEditPage {...props} />;
}
