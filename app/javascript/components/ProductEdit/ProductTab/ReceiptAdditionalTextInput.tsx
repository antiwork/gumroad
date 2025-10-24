import * as React from "react";

type Props = {
  id: string;
  value: string;
  onChange: (value: string) => void;
};

export const ReceiptAdditionalTextInput: React.FC<Props> = ({ id, value, onChange }) => {
  return (
    <fieldset>
      <label htmlFor={id}>Receipt additional text</label>
      <textarea
        id={id}
        maxLength={100}
        placeholder="Optional note shown on the receipt and receipt email"
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value.slice(0, 100))}
      />
      <div className="hint">Shown under the receipt header in both the web receipt and email. Max 100 characters.</div>
    </fieldset>
  );
};

export default ReceiptAdditionalTextInput;
