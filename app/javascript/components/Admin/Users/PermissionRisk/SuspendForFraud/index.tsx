import React from "react";

import AdminSuspendForFraudForm from "$app/components/Admin/Users/PermissionRisk/SuspendForFraud/Form";
import type { User } from "$app/components/Admin/Users/User";

type SuspendForFraudProps = {
  user: User;
};

const SuspendForFraud = ({ user }: SuspendForFraudProps) => {
  const show = user.flagged_for_fraud || user.on_probation;

  return (
    show && (
      <>
        <hr />
        <details>
          <summary>
            <h3>Suspend for fraud</h3>
          </summary>
          <AdminSuspendForFraudForm user_id={user.id} />
        </details>
      </>
    )
  );
};

export default SuspendForFraud;
