import * as React from "react";

export const CustomViewContentButtonTextInput = ({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (value: string) => void;
}) => {
  const uid = React.useId();
  return (
    <fieldset>
      <label htmlFor={uid}>Receipt button text</label>
      <input
        id={uid}
        type="text"
        placeholder="View content"
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
      />
      <p
        style={{
          fontSize: "var(--font-size-small)",
          color: "var(--color-text-secondary)",
          marginTop: "var(--spacer-1)",
        }}
      >
        Customize the text of the button in the receipt email (e.g., "Join the community", "See your content").
      </p>
    </fieldset>
  );
};
