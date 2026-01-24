import { usePage } from "@inertiajs/react";
import React, { ComponentProps } from "react";

import { default as ProductEditPage } from "$app/components/server-components/ProductEditPage";

type ProductEditPageProps = ComponentProps<typeof ProductEditPage>;

function Edit() {
  const props = usePage<ProductEditPageProps>().props;

  return <ProductEditPage {...props} />;
}

export default Edit;
