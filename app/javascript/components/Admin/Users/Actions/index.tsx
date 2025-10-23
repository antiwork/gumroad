import React from "react";

import ConfirmEmailAction from "$app/components/Admin/Users/Actions/ConfirmEmailAction";
import ImpersonateAction from "$app/components/Admin/Users/Actions/ImpersonateAction";
import InvalidateActiveSessionsAction from "$app/components/Admin/Users/Actions/InvalidateActiveSessionsAction";
import MarkAsAdultAction from "$app/components/Admin/Users/Actions/MarkAsAdultAction";
import ResetPasswordAction from "$app/components/Admin/Users/Actions/ResetPasswordAction";
import UndeleteAction from "$app/components/Admin/Users/Actions/UndeleteAction";
import VerifyAction from "$app/components/Admin/Users/Actions/VerifyAction";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserActionsProps = {
  user: User;
};

const AdminUserActions = ({ user }: AdminUserActionsProps) => (
  <div className="button-group">
    <ImpersonateAction user={user} />
    <VerifyAction user={user} />
    <UndeleteAction user={user} />
    <ResetPasswordAction user={user} />
    <ConfirmEmailAction user={user} />
    <InvalidateActiveSessionsAction user={user} />
    <MarkAsAdultAction user={user} />
  </div>
);

export default AdminUserActions;
