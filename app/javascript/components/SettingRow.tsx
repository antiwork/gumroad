import * as React from "react";

import { Details } from "$app/components/Details";
import { Toggle } from "$app/components/Toggle";
import { WithTooltip } from "$app/components/WithTooltip";

type ToggleProps = {
  label: string;
  value: boolean;
  help?: { url?: string; dataHelperPrompt?: string; label: string | React.ReactNode; tooltip?: string };
  onChange?: (newValue: boolean) => void;
  dropdown?: React.ReactNode;
  disabled?: boolean;
};
export const ToggleSettingRow = ({ label, value, help, onChange, dropdown, disabled }: ToggleProps) => {
  const toggle = (
    <Toggle value={value} onChange={onChange} disabled={Boolean(disabled)}>
      {label}
      {help?.url || help?.dataHelperPrompt ? (
        <span className="ml-2">
          <WithTooltip tip={help.tooltip || null} position="top">
            {help.url ? (
              <a
                href={help.url}
                target="_blank"
                rel="noopener noreferrer"
                className="learn-more"
                style={{ flexShrink: 0 }}
              >
                {help.label}
              </a>
            ) : (
              <a data-helper-prompt={help.dataHelperPrompt} className="learn-more" style={{ flexShrink: 0 }}>
                {help.label}
              </a>
            )}
          </WithTooltip>
        </span>
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
