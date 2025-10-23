import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { showAlert } from "$app/components/server-components/Alert";

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
          <Form
            url={Routes.suspend_for_fraud_admin_user_path(user.id)}
            method="POST"
            confirmMessage={`Are you sure you want to suspend user ${user.id} for fraud?`}
            onSuccess={() => showAlert("Suspended.", "success")}
          >
            {(isLoading) => (
              <fieldset>
                <div className="input-with-button" style={{ alignItems: "start" }}>
                  <textarea
                    name="suspend_for_fraud[suspension_note]"
                    rows={3}
                    placeholder="Add suspension note (optional)"
                  />
                  <button type="submit" className="button" disabled={isLoading}>
                    {isLoading ? "Submitting..." : "Submit"}
                  </button>
                </div>
              </fieldset>
            )}
          </Form>
        </details>
      </>
    )
  );
};

export default SuspendForFraud;
