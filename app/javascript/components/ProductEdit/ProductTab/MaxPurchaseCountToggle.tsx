import * as React from "react";

import { Dropdown } from "$app/components/Dropdown";
import { NumberInput } from "$app/components/NumberInput";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
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
    <Details open={isEnabled}>
      <DetailsToggle chevronPosition="none" className="mb-0">
        <Switch checked={isEnabled} onChange={(e) => setIsEnabled(e.target.checked)} label="Limit product sales" />
      </DetailsToggle>
      <Dropdown>
        <Fieldset>
          <Label htmlFor={`${uid}-max-purchase-count`}>Maximum number of purchases</Label>
          <WithTooltip tip="Total sales">
            <NumberInput value={count} onChange={setCount}>
              {(props) => <Input id={`${uid}-max-purchase-count`} placeholder="∞" {...props} />}
            </NumberInput>
          </WithTooltip>
        </Fieldset>
      </Dropdown>
    </Details>
  );
};
