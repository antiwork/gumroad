import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type UnmarkAsStaffPickedActionProps = {
  product: Product;
};

const UnmarkAsStaffPickedAction = ({ product }: UnmarkAsStaffPickedActionProps) =>
  product.admins_can_unmark_as_staff_picked && (
    <AdminActionButton
      url={Routes.admin_product_staff_picked_path(product.external_id)}
      method="DELETE"
      label="Unmark as staff-picked"
      loading="Unmarking as staff-picked..."
      done="Unmarked as staff-picked!"
      success_message="Unmarked as staff-picked!"
    />
  );

export default UnmarkAsStaffPickedAction;
