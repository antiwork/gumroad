import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type DeleteActionProps = {
  product: Product;
};

const DeleteAction = ({ product }: DeleteActionProps) =>
  product.deleted_at ? (
    <AdminActionButton
      url={Routes.restore_admin_product_path(product.unique_permalink)}
      label="Undelete"
      loading="Undeleting..."
      done="Undeleted!"
      success_message="Undeleted!"
    />
  ) : (
    <AdminActionButton
      url={Routes.admin_product_path(product.unique_permalink)}
      method="DELETE"
      label="Delete"
      loading="Deleting..."
      done="Deleted!"
      success_message="Deleted!"
    />
  );

export default DeleteAction;
