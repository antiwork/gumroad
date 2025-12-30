import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type MarkAsStaffPickedActionProps = {
  product: Product;
};

const MarkAsStaffPickedAction = ({ product }: MarkAsStaffPickedActionProps) =>
  product.admins_can_mark_as_staff_picked && (
    <AdminActionButton
      url={Routes.admin_product_staff_picked_path(product.external_id)}
      label="Mark as staff-picked"
      loading="Marking as staff-picked..."
      done="Marked as staff-picked!"
      success_message="Marked as staff-picked!"
    />
  );

export default MarkAsStaffPickedAction;
