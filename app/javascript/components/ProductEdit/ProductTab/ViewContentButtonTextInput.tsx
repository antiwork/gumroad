import * as React from "react";

type Props = {
  id: string;
  value?: string | null;
  onChange: (value: string) => void;
};

export const ViewContentButtonTextInput: React.FC<Props> = ({ id, value, onChange }) => {
  const val = value ?? "View Content";

  return (
    <fieldset>
      <label htmlFor={id}>View Content button text</label>
      <input
        id={id}
        type="text"
        maxLength={26}
        placeholder="View Content"
        value={val}
        onChange={(evt) => onChange(evt.target.value.slice(0, 25))}
      />
      <div className="hint">Used for the customer “View content” CTA after purchase. Max 26 characters.</div>
    </fieldset>
  );
};

export default ViewContentButtonTextInput;
