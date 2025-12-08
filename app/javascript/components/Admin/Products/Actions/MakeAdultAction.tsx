import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type MakeAdultActionProps = {
  product: Product;
};

const MakeAdultAction = ({ product }: MakeAdultActionProps) =>
  product.is_adult ? (
    <AdminActionButton
      url={Routes.is_adult_admin_product_path(product.id, { is_adult: "0" })}
      label="Make non-adult"
      loading="Making non-adult..."
      done="It's not adult!"
      success_message="It's not adult!"
    />
  ) : (
    <AdminActionButton
      url={Routes.is_adult_admin_product_path(product.id, { is_adult: "1" })}
      label="Make adult"
      loading="Making adult..."
      done="It's adult!"
      success_message="It's adult!"
    />
  );

export default MakeAdultAction;
