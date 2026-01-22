import * as React from "react";

import { Details } from "$app/components/Details";
import { NumberInput } from "$app/components/NumberInput";
import { Toggle } from "$app/components/Toggle";
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
        <Toggle value={isEnabled} onChange={setIsEnabled}>
          Giới hạn số lượng bán
        </Toggle>
      }
    >
      <div className="dropdown">
        <fieldset>
          <label htmlFor={`${uid}-max-purchase-count`}>Số lượng mua tối đa</label>
          <WithTooltip tip="Tổng số bán">
            <NumberInput value={count} onChange={setCount}>
              {(props) => <input id={`${uid}-max-purchase-count`} placeholder="∞" {...props} />}
            </NumberInput>
          </WithTooltip>
        </fieldset>
      </div>
    </Details>
  );
};
