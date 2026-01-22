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
      <label htmlFor={uid}>Tin nhắn tùy chỉnh</label>
      <textarea
        id={uid}
        maxLength={maxLength}
        placeholder="Thêm bất kỳ thông tin bổ sung nào bạn muốn đưa vào biên lai."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
    </fieldset>
  );
};
