import * as React from "react";

import { Dropdown } from "$app/components/Dropdown";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Switch } from "$app/components/ui/Switch";

type ToggleProps = {
  label: string;
  value: boolean;
  help?: { url?: string; label: string | React.ReactNode; tooltip?: string };
  onChange?: (newValue: boolean) => void;
  dropdown?: React.ReactNode;
  disabled?: boolean;
};
export const ToggleSettingRow = ({ label, value, help, onChange, dropdown, disabled }: ToggleProps) => {
  const toggle = (
    <Switch
      checked={value}
      onChange={(e) => onChange?.(e.target.checked)}
      disabled={Boolean(disabled)}
      label={
        <>
          {label}
          {help?.url ? (
            <>
              {" "}
              <a
                href={help.url}
                target="_blank"
                rel="noopener noreferrer"
                className="learn-more"
                style={{ flexShrink: 0 }}
              >
                {help.label}
              </a>
            </>
          ) : null}
        </>
      }
    />
  );
  return dropdown ? (
    <Details open={value}>
      <DetailsToggle chevronPosition="none" className="mb-0">
        {toggle}
      </DetailsToggle>
      <Dropdown>{dropdown}</Dropdown>
    </Details>
  ) : (
    toggle
  );
};
