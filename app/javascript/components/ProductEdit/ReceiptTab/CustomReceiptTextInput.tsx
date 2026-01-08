import * as React from "react";

export const CustomReceiptTextInput = ({
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
      <label htmlFor={uid}>Message from the creator</label>
      <textarea
        id={uid}
        maxLength={maxLength}
        placeholder="Shown to buyers on the receipt."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
    </fieldset>
  );
};
