import { usePage } from "@inertiajs/react";
import React from "react";

import { ProductEditPage, type Props as ProductEditPageProps } from "$app/components/server-components/ProductEditPage";

function Edit() {
  const props = usePage<ProductEditPageProps>().props;

  return <ProductEditPage {...props} />;
}

export default Edit;
