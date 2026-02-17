import * as React from "react";

import { asyncVoid } from "$app/utils/promise";
import { request } from "$app/utils/request";

import { usePurchaseCustomFields, usePurchaseInfo } from "$app/components/DownloadPage/WithContent";
import { showAlert } from "$app/components/server-components/Alert";

export const TextInput = ({
  customFieldId,
  type,
  label,
}: {
  customFieldId: string;
  type: "shortAnswer" | "longAnswer";
  label: string;
}) => {
  const uid = React.useId();
  const purchaseInfo = usePurchaseInfo();
  const purchaseCustomFields = usePurchaseCustomFields();

  const [value, setValue] = React.useState(() => {
    const purchaseCustomField = purchaseCustomFields.find(
      (purchaseCustomField) => purchaseCustomField.custom_field_id === customFieldId,
    );
    if (purchaseCustomField?.type !== type) return "";
    return purchaseCustomField.value;
  });

  const [isLoading, setIsLoading] = React.useState(false);
  const [savedValue, setSavedValue] = React.useState(value);

  const sharedInputProps: React.InputHTMLAttributes<HTMLInputElement | HTMLTextAreaElement> = {
    id: uid,
    value,
    onChange: (evt) => setValue(evt.target.value),
    onBlur: asyncVoid(async (evt) => {
      const newValue = evt.target.value;
      if (newValue === savedValue) return;
      setIsLoading(true);
      await request({
        method: "POST",
        accept: "json",
        url: Routes.purchase_custom_fields_path(),
        data: {
          purchase_id: purchaseInfo.purchaseId,
          custom_field_id: customFieldId,
          value: newValue,
        },
      });
      setIsLoading(false);
      setSavedValue(newValue);
      showAlert("Response saved!", "success");
    }),
    disabled: isLoading,
  };

  return (
    <>
      <label htmlFor={uid}>{label}</label>
      {type === "shortAnswer" ? <input {...sharedInputProps} /> : <textarea {...sharedInputProps} />}
    </>
  );
};
