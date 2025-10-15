import React from "react";

import AdminFlagForFraudForm from "$app/components/Admin/Users/PermissionRisk/FlagForFraud/Form";
import type { User } from "$app/components/Admin/Users/User";

type FlagForFraudProps = {
  user: User;
};

const FlagForFraud = ({ user }: FlagForFraudProps) => {
  const hide = user.flagged_for_fraud || user.on_probation || user.suspended;

  return (
    !hide && (
      <>
        <hr />
        <details>
          <summary>
            <h3>Flag for fraud</h3>
          </summary>
          <AdminFlagForFraudForm user_id={user.id} />
        </details>
      </>
    )
  );
};

export default FlagForFraud;
