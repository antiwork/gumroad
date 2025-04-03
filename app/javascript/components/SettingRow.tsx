import * as React from "react";

import { Details } from "$app/components/Details";
import { Toggle } from "$app/components/Toggle";
import { WithTooltip } from "$app/components/WithTooltip";

type ToggleProps = {
  label: string;
  value: boolean;
  help?: { url: string; label: string | React.ReactNode; tooltip?: string };
  onChange?: (newValue: boolean) => void;
  dropdown?: React.ReactNode;
  disabled?: boolean;
};
export const ToggleSettingRow = ({ label, value, help, onChange, dropdown, disabled }: ToggleProps) => {
  const toggle = (
    <Toggle value={value} onChange={onChange} disabled={Boolean(disabled)}>
      {label}
      {help ? (
        <WithTooltip tip={help.tooltip || null} position="top">
          <a href={help.url} target="_blank" rel="noopener noreferrer" className="learn-more" style={{ flexShrink: 0 }}>
            {help.label}
          </a>
        </WithTooltip>
      ) : null}
    </Toggle>
  );
  return dropdown ? (
    <Details summary={toggle} className="toggle" open={value}>
      <div className="dropdown">{dropdown}</div>
    </Details>
  ) : (
    toggle
  );
};
