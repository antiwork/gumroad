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
      <label htmlFor={uid}>Văn bản nút</label>
      <input
        id={uid}
        type="text"
        placeholder="Xem nội dung"
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        maxLength={maxLength}
      />
      <small>Tùy chỉnh văn bản nút tải xuống trên biên lai và trang sản phẩm (tối đa {maxLength} ký tự).</small>
    </fieldset>
  );
};
