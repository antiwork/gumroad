import * as React from "react";

export const CustomSummaryInput = ({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (value: string) => void;
}) => {
  const uid = React.useId();
  return (
    <fieldset>
      <label htmlFor={uid}>Summary</label>
      <input
        id={uid}
        type="text"
        placeholder="You'll get..."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
      />
    </fieldset>
  );
};
