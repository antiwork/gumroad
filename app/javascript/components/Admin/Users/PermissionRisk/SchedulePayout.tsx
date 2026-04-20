import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

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
          <Form
            url={Routes.schedule_payout_admin_user_path(user.external_id)}
            method="POST"
            confirmMessage={`Are you sure you want to schedule a ${payoutAction} for user ${user.external_id}?`}
            onSuccess={() => showAlert("Scheduled.", "success")}
          >
            {(isLoading) => (
              <Fieldset>
                <div className="flex items-end gap-2">
                  <div className="flex flex-1 flex-col gap-2">
                    <Label htmlFor="scheduled_payout_action">Balance action</Label>
                    <Select
                      id="scheduled_payout_action"
                      name="scheduled_payout[action]"
                      value={payoutAction}
                      onChange={(e) => setPayoutAction(e.target.value)}
                    >
                      <option value="payout">Payout after delay</option>
                      <option value="refund">Refund purchases</option>
                      <option value="hold">Hold (manual release)</option>
                    </Select>
                  </div>
                  {payoutAction !== "hold" && (
                    <div className="flex w-24 flex-col gap-2">
                      <Label htmlFor="scheduled_payout_delay">Delay (days)</Label>
                      <Input
                        id="scheduled_payout_delay"
                        type="number"
                        name="scheduled_payout[delay_days]"
                        defaultValue={21}
                        min={0}
                      />
                    </div>
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

export default SchedulePayout;
