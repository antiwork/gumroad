import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { ScheduledPayoutFields } from "$app/components/Admin/Users/PermissionRisk/ScheduledPayoutFields";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";

type SchedulePayoutProps = {
  user: User;
};

const SchedulePayout = ({ user }: SchedulePayoutProps) => {
  const [payoutAction, setPayoutAction] = React.useState("payout");

  return (
    user.suspended &&
    user.unpaid_balance_cents > 0 && (
      <>
        <hr />
        <Details>
          <DetailsToggle>
            <h3>Schedule payout</h3>
          </DetailsToggle>
          {user.has_in_progress_scheduled_payout ? (
            <Alert variant="info">
              This user already has an in-progress scheduled payout. Cancel or wait for it to complete before scheduling
              another.
            </Alert>
          ) : (
            <Form
              url={Routes.schedule_payout_admin_user_path(user.external_id)}
              method="POST"
              confirmMessage={`Are you sure you want to schedule a ${payoutAction} for user ${user.external_id}?`}
              onSuccess={() => showAlert("Scheduled.", "success")}
            >
              {(isLoading) => (
                <Fieldset>
                  <div className="flex items-end gap-2">
                    <ScheduledPayoutFields action={payoutAction} onActionChange={setPayoutAction} />
                    <Button type="submit" disabled={isLoading}>
                      {isLoading ? "Submitting..." : "Submit"}
                    </Button>
                  </div>
                </Fieldset>
              )}
            </Form>
          )}
        </Details>
      </>
    )
  );
};

export default SchedulePayout;
