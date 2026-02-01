import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Textarea } from "$app/components/ui/Textarea";

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
            url={Routes.suspend_for_fraud_admin_user_path(user.external_id)}
            method="POST"
            confirmMessage={`Are you sure you want to suspend user ${user.external_id} for fraud?`}
            onSuccess={() => showAlert("Suspended.", "success")}
          >
            {(isLoading) => (
              <Fieldset>
                <div className="flex items-start gap-2">
                  <Textarea
                    name="suspend_for_fraud[suspension_note]"
                    rows={3}
                    className="flex-1"
                    placeholder="Add suspension note (optional)"
                  />
                  <Button type="submit" disabled={isLoading}>
                    {isLoading ? "Submitting..." : "Submit"}
                  </Button>
                </div>
              </Fieldset>
            )}
          </Form>
        </details>
      </>
    )
  );
};

export default SuspendForFraud;
