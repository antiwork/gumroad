import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { showAlert } from "$app/components/server-components/Alert";

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
          <Form
            url={Routes.flag_for_fraud_admin_user_path(user.external_id)}
            method="POST"
            confirmMessage={`Are you sure you want to flag user ${user.external_id} for fraud?`}
            onSuccess={() => showAlert("Flagged.", "success")}
          >
            {(isLoading) => (
              <fieldset>
                <div className="flex items-start gap-2">
                  <textarea
                    name="flag_for_fraud[flag_note]"
                    className="flex-1"
                    rows={3}
                    placeholder="Add flag note (optional)"
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

export default FlagForFraud;
