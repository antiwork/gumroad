import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type InvalidateActiveSessionsProps = {
  user: User;
};

const InvalidateActiveSessions = ({ user: { id } }: InvalidateActiveSessionsProps) => (
  <AdminAction
    label="Sign out from all active sessions"
    url={Routes.invalidate_active_sessions_admin_user_path(id)}
    confirm_message={`Are you sure you want to sign out user ${id} from all active sessions?`}
    loading="Signing out from all active sessions..."
    success_message="Signed out from all active sessions."
    done="Signed out from all active sessions."
  />
);

export default InvalidateActiveSessions;
