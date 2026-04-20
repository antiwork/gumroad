import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { ScheduledPayoutFields } from "$app/components/Admin/Users/PermissionRisk/ScheduledPayoutFields";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Textarea } from "$app/components/ui/Textarea";

type SuspendForFraudProps = {
  user: User;
};

const SuspendForFraud = ({ user }: SuspendForFraudProps) => {
  const show = user.flagged_for_fraud || user.on_probation;
  const [payoutAction, setPayoutAction] = React.useState("payout");

  return (
    show && (
      <>
        <hr />
        <Details>
          <DetailsToggle>
            <h3>Suspend for fraud</h3>
          </DetailsToggle>
          <Form
            url={Routes.suspend_for_fraud_admin_user_path(user.external_id)}
            method="POST"
            confirmMessage={`Are you sure you want to suspend user ${user.external_id} for fraud?`}
            onSuccess={() => showAlert("Suspended.", "success")}
          >
            {(isLoading) => (
              <Fieldset>
                <Textarea
                  name="suspend_for_fraud[suspension_note]"
                  rows={3}
                  placeholder="Add suspension note (optional)"
                />
                <div className="flex items-end gap-2">
                  {user.unpaid_balance_cents > 0 && !user.has_in_progress_scheduled_payout && (
                    <ScheduledPayoutFields action={payoutAction} onActionChange={setPayoutAction} />
                  )}
                  <Button type="submit" disabled={isLoading}>
                    {isLoading ? "Submitting..." : "Submit"}
                  </Button>
                </div>
              </Fieldset>
            )}
          </Form>
        </Details>
      </>
    )
  );
};

export default SuspendForFraud;
