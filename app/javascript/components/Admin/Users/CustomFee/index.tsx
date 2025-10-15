import React from "react";

import AdminSetCustomFeeForm from "$app/components/Admin/Users/CustomFee/Form";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserCustomFeeProps = {
  user: User;
};

const AdminUserCustomFee = ({ user }: AdminUserCustomFeeProps) => (
  <>
    <hr />
    <details>
      <summary>
        <h3>Custom fee</h3>
      </summary>
      <AdminSetCustomFeeForm user_id={user.id} custom_fee_percent={user.custom_fee_percent} />
    </details>
  </>
);

export default AdminUserCustomFee;
