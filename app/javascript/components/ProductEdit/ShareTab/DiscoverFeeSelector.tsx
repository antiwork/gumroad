import * as React from "react";

import { Details } from "$app/components/Details";
import { NumberInput } from "$app/components/NumberInput";
import { Toggle } from "$app/components/Toggle";

export const DiscoverFeeSelector = ({ value, onChange }: { value: number; onChange: (value: number) => void }) => {
  const uid = React.useId();

  const [boostProductVisibility, setBoostProductVisibility] = React.useState(value >= 300);

  return (
    <Details
      className="toggle"
      open={boostProductVisibility}
      summary={
        <Toggle
          value={boostProductVisibility}
          onChange={(newValue) => {
            setBoostProductVisibility(newValue);
            onChange(newValue ? 300 : 100);
          }}
        >
          <a data-helper-prompt="How does Gumroad recommendations help bring product visibility?">
            Boost your product's visibility
          </a>{" "}
          in Gumroad recommendations
        </Toggle>
      }
    >
      <div className="dropdown paragraphs">
        <p>Increase your product visibility by setting a higher fee. The higher the fee the better the boost.</p>
        <fieldset>
          <label htmlFor={uid}>Gumroad Fee</label>
          <div className="input">
            <NumberInput
              value={value !== 0 ? value / 10 : null}
              onChange={(newValue) => onChange(newValue ? newValue * 10 : 0)}
            >
              {(props) => <input id={uid} min="30" max="100" {...props} />}
            </NumberInput>
            <div className="pill">%</div>
          </div>
          <small>
            {value < 300 || value > 1000
              ? "Please enter a value between 30 and 100."
              : "Minimum boost fee starts at 30%"}
          </small>
        </fieldset>
      </div>
    </Details>
  );
};
