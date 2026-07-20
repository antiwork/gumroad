import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import type { User } from "$app/components/Admin/Users/User";

type UnlockEmailSendingActionProps = {
  user: User;
};

// Admin-granted exception (gumroad-private#1192): lets a credible seller send
// emails before their first completed payout (e.g. the payout is stuck in
// transit). Only the completed-payout requirement is waived — the $100 minimum
// sales requirement still applies. The entered reason is recorded as an audit
// comment on the user.
const UnlockEmailSendingAction = ({ user }: UnlockEmailSendingActionProps) =>
  !user.email_sending_unlocked_by_admin && (
    <AdminAction
      label="Unlock email sending"
      url={Routes.unlock_email_sending_admin_user_path(user.external_id)}
      confirm_message="Unlock email sending for this user before their first completed payout? The $100 minimum sales requirement still applies."
      prompt_message="Reason for unlocking email sending (recorded as an audit comment):"
      prompt_field_name="reason"
      loading="Unlocking email sending..."
      done="Email sending unlocked"
      success_message="Email sending unlocked!"
      outline
      color="warning"
    />
  );

export default UnlockEmailSendingAction;
