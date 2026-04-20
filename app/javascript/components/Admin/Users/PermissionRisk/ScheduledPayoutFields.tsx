import * as React from "react";

import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

export const ScheduledPayoutFields = ({
  action,
  onActionChange,
}: {
  action: string;
  onActionChange: (action: string) => void;
}) => (
  <>
    <div className="flex flex-1 flex-col gap-2">
      <Label htmlFor="scheduled_payout_action">Balance action</Label>
      <Select
        id="scheduled_payout_action"
        name="scheduled_payout[action]"
        value={action}
        onChange={(e) => onActionChange(e.target.value)}
      >
        <option value="payout">Payout after delay</option>
        <option value="refund">Refund purchases</option>
        <option value="hold">Hold (manual release)</option>
      </Select>
    </div>
    {action !== "hold" && (
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
  </>
);
