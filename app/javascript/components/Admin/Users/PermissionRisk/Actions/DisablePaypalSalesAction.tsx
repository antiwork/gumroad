import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import type { User } from "$app/components/Admin/Users/User";

type DisablePaypalSalesActionProps = {
  user: User;
};

const DisablePaypalSalesAction = ({ user }: DisablePaypalSalesActionProps) =>
  !user.disable_paypal_sales && (
    <AdminAction
      label="Disable PayPal sales"
      url={Routes.disable_paypal_sales_admin_user_path(user.id)}
      loading="Disabling PayPal sales..."
      done="PayPal sales disabled!"
      success_message="PayPal sales disabled!"
      outline
      color="warning"
    />
  );

export default DisablePaypalSalesAction;
