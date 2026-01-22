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
      <label htmlFor={uid}>Tóm tắt</label>
      <input
        id={uid}
        type="text"
        placeholder="Bạn sẽ nhận được..."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
      />
    </fieldset>
  );
};
