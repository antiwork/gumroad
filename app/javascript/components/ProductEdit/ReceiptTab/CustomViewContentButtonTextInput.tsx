import * as React from "react";

export const CustomViewContentButtonTextInput = ({
  value,
  onChange,
  maxLength,
}: {
  value: string | null;
  onChange: (value: string) => void;
  maxLength: number;
}) => {
  const uid = React.useId();
  return (
    <fieldset>
      <label htmlFor={uid}>Button text</label>
      <input
        id={uid}
        type="text"
        placeholder="View content"
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        maxLength={maxLength}
      />
      <small>Customize the download button text on receipts and product pages (max {maxLength} characters).</small>
    </fieldset>
  );
};
