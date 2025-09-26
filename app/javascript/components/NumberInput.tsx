import * as React from "react";

type Props = {
  children: (inputValueProps: {
    onChange: (evt: React.ChangeEvent<HTMLInputElement>) => void;
    value: string;
    inputMode: "numeric" | "decimal";
  }) => React.ReactElement;
  onChange: (newValue: null | number) => void;
  value: null | number;
  decimal?: boolean;
};
export const NumberInput = ({ children, onChange, value, decimal }: Props) =>
  children({
    onChange: (evt: React.ChangeEvent<HTMLInputElement>) => {
      const numericString = evt.target.value.replace(decimal ? /[^\d.]/u : /\D/gu, "");
      const value = numericString.length > 0 ? parseInt(numericString, 10) : null;

      onChange(value);
    },
    value: value != null ? value.toFixed(0) : "",
    inputMode: decimal ? "decimal" : "numeric",
  });
