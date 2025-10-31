import * as React from "react";

export const CustomReceiptTextInput = ({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (value: string) => void;
}) => {
  const uid = React.useId();
  return (
    <fieldset>
      <label htmlFor={uid}>Additional receipt text</label>
      <textarea
        id={uid}
        placeholder="Add a message to your receipt emails..."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
      <p
        style={{
          fontSize: "var(--font-size-small)",
          color: "var(--color-text-secondary)",
          marginTop: "var(--spacer-1)",
        }}
      >
        This text will appear in the receipt email sent to customers after purchase.
      </p>
    </fieldset>
  );
};
