import * as React from "react";

import { Details } from "$app/components/Details";
import { Dropdown } from "$app/components/Dropdown";
import { NumberInput } from "$app/components/NumberInput";
import { Switch } from "$app/components/ui/Switch";
import { WithTooltip } from "$app/components/WithTooltip";

export const MaxPurchaseCountToggle = ({
  maxPurchaseCount,
  setMaxPurchaseCount,
}: {
  maxPurchaseCount: number | null;
  setMaxPurchaseCount: (maxPurchaseCount: number | null) => void;
}) => {
  const [count, setCount] = React.useState<number | null>(maxPurchaseCount);
  const [isEnabled, setIsEnabled] = React.useState(maxPurchaseCount != null);

  React.useEffect(() => setMaxPurchaseCount(isEnabled ? count : null), [count, isEnabled]);

  const uid = React.useId();

  return (
    <Details
      className="toggle"
      open={isEnabled}
      summary={
        <Switch checked={isEnabled} onChange={(e) => setIsEnabled(e.target.checked)} label="Limit product sales" />
      }
    >
      <Dropdown>
        <fieldset>
          <label htmlFor={`${uid}-max-purchase-count`}>Maximum number of purchases</label>
          <WithTooltip tip="Total sales">
            <NumberInput value={count} onChange={setCount}>
              {(props) => <input id={`${uid}-max-purchase-count`} placeholder="∞" {...props} />}
            </NumberInput>
          </WithTooltip>
        </fieldset>
      </Dropdown>
    </Details>
  );
};
