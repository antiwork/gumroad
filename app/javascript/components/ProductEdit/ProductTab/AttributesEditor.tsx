import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";

export type Attribute = { name: string; value: string };

export const AttributesEditor = ({
  customAttributes,
  setCustomAttributes,
  fileAttributes,
  setFileAttributes,
}: {
  customAttributes: Attribute[];
  setCustomAttributes: (newCustomAttributes: Attribute[]) => void;
  fileAttributes?: Attribute[];
  setFileAttributes?: (newFileAttributes: Attribute[]) => void;
}) => {
  const updateCustomAttribute = (idx: number, update: Partial<Attribute>) => {
    const customAttribute = customAttributes[idx];
    if (!customAttribute) return;
    setCustomAttributes([
      ...customAttributes.slice(0, idx),
      { ...customAttribute, ...update },
      ...customAttributes.slice(idx + 1),
    ]);
  };

  const addButton = (
    <Button color="primary" onClick={() => setCustomAttributes([...customAttributes, { name: "", value: "" }])}>
      <Icon name="plus" />
      Add detail
    </Button>
  );

  return (
    <fieldset>
      <legend>Additional details</legend>
      {(fileAttributes?.length ?? 0) > 0 || customAttributes.length > 0 ? (
        <>
          {fileAttributes?.map((attribute, idx) => (
            <AttributeEditor
              attribute={attribute}
              onDelete={() => setFileAttributes?.(fileAttributes.filter((_, index) => idx !== index))}
              key={idx}
            />
          ))}
          {customAttributes.map((attribute, idx) => (
            <AttributeEditor
              attribute={attribute}
              onUpdate={(update) => updateCustomAttribute(idx, update)}
              onDelete={() => setCustomAttributes(customAttributes.filter((_, index) => idx !== index))}
              key={idx}
            />
          ))}
          {addButton}
        </>
      ) : (
        <div className="placeholder">
          <h2>Add details</h2>
          Call out important features of your product that help your customers decide to buy
          {addButton}
        </div>
      )}
    </fieldset>
  );
};

const AttributeEditor = ({
  attribute,
  onUpdate,
  onDelete,
}: {
  attribute: Attribute;
  onUpdate?: (update: Partial<Attribute>) => void;
  onDelete: () => void;
}) => (
  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr max-content", gap: "var(--spacer-2)" }}>
    <input
      type="text"
      value={attribute.name}
      onChange={(evt) => onUpdate?.({ name: evt.target.value })}
      disabled={!onUpdate}
    />
    <input
      type="text"
      value={attribute.value}
      onChange={(evt) => onUpdate?.({ value: evt.target.value })}
      disabled={!onUpdate}
    />
    <Button onClick={onDelete}>
      <Icon name="trash2" />
    </Button>
  </div>
);
