import React from "react";

import DisablePaypalSalesAction from "$app/components/Admin/Users/PermissionRisk/Actions/DisablePaypalSalesAction";
import MarkCompliantAction from "$app/components/Admin/Users/PermissionRisk/Actions/MarkCompliantAction";
import RefundBalanceAction from "$app/components/Admin/Users/PermissionRisk/Actions/RefundBalanceAction";
import FlagForFraud from "$app/components/Admin/Users/PermissionRisk/FlagForFraud";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserPermissionRiskActionsProps = {
  user: User;
};

const AdminUserPermissionRiskActions = ({ user }: AdminUserPermissionRiskActionsProps) => (
  <div className="flex flex-wrap gap-2">
    <MarkCompliantAction user={user} />
    <RefundBalanceAction user={user} />
    <DisablePaypalSalesAction user={user} />
    <FlagForFraud user={user} />
  </div>
);

export default AdminUserPermissionRiskActions;
