import * as React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";

type FlagForFraudProps = {
  user: User;
};

const FlagForFraud = ({ user }: FlagForFraudProps) => {
  const hide = user.flagged_for_fraud || user.on_probation || user.suspended;

  const suspendUrl = `${Routes.admin_suspend_users_url()}?identifiers=${encodeURIComponent(user.external_id)}`;

  return (
    !hide && (
      <Button
        size="sm"
        color="danger"
        onClick={() => { window.location.href = suspendUrl; }}
      >
        Suspend for fraud
      </Button>
    )
  );
};

export default FlagForFraud;
