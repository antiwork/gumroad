import { ArrowDown, ArrowUp, Plus, Trash } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Placeholder } from "$app/components/ui/Placeholder";

export type Attribute = { name: string; value: string };

export const AttributesEditor = ({
  customAttributes,
  setCustomAttributes,
  fileAttributes,
  setFileAttributes,
  nameSuggestions = [],
}: {
  customAttributes: Attribute[];
  setCustomAttributes: (newCustomAttributes: Attribute[]) => void;
  fileAttributes?: Attribute[];
  setFileAttributes?: (newFileAttributes: Attribute[]) => void;
  // Names this seller has used on their other products. Offered as suggestions so a name they
  // already use elsewhere is picked rather than retyped — buyers see the name on the product page.
  nameSuggestions?: string[];
}) => {
  // React's useId contains colons, which happy-dom resolves `input[list]` through querySelector and
  // rejects. A plain id keeps the datalist wireable in the component tests.
  const nameSuggestionsId = React.useId().replace(/:/gu, "");

  const updateCustomAttribute = (idx: number, update: Partial<Attribute>) => {
    const customAttribute = customAttributes[idx];
    if (!customAttribute) return;
    setCustomAttributes([
      ...customAttributes.slice(0, idx),
      { ...customAttribute, ...update },
      ...customAttributes.slice(idx + 1),
    ]);
  };

  const moveCustomAttribute = (idx: number, to: number) => {
    const customAttribute = customAttributes[idx];
    if (!customAttribute || to < 0 || to >= customAttributes.length) return;
    const reordered = [...customAttributes];
    reordered.splice(idx, 1);
    reordered.splice(to, 0, customAttribute);
    setCustomAttributes(reordered);
  };

  const addButton = (
    <Button color="primary" onClick={() => setCustomAttributes([...customAttributes, { name: "", value: "" }])}>
      <Plus className="size-5" />
      Add detail
    </Button>
  );

  return (
    <Fieldset>
      <FieldsetTitle>Additional details</FieldsetTitle>
      <datalist id={nameSuggestionsId}>
        {nameSuggestions.map((name) => (
          <option key={name} value={name} />
        ))}
      </datalist>
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
              nameSuggestionsId={nameSuggestionsId}
              onUpdate={(update) => updateCustomAttribute(idx, update)}
              onDelete={() => setCustomAttributes(customAttributes.filter((_, index) => idx !== index))}
              onMoveUp={idx === 0 ? undefined : () => moveCustomAttribute(idx, idx - 1)}
              onMoveDown={idx === customAttributes.length - 1 ? undefined : () => moveCustomAttribute(idx, idx + 1)}
              key={idx}
            />
          ))}
          {addButton}
        </>
      ) : (
        <Placeholder>
          <h2>Add details</h2>
          Call out important features of your product that help your customers decide to buy
          {addButton}
        </Placeholder>
      )}
    </Fieldset>
  );
};

const AttributeEditor = ({
  attribute,
  nameSuggestionsId,
  onUpdate,
  onDelete,
  onMoveUp,
  onMoveDown,
}: {
  attribute: Attribute;
  nameSuggestionsId?: string;
  onUpdate?: (update: Partial<Attribute>) => void;
  onDelete: () => void;
  onMoveUp?: (() => void) | undefined;
  onMoveDown?: (() => void) | undefined;
}) => (
  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr max-content", gap: "var(--spacer-2)" }}>
    <Input
      type="text"
      list={nameSuggestionsId}
      value={attribute.name}
      onChange={(evt) => onUpdate?.({ name: evt.target.value })}
      disabled={!onUpdate}
    />
    <Input
      type="text"
      value={attribute.value}
      onChange={(evt) => onUpdate?.({ value: evt.target.value })}
      disabled={!onUpdate}
    />
    <div style={{ display: "flex", gap: "var(--spacer-2)" }}>
      {onUpdate ? (
        <>
          <Button aria-label="Move detail up" disabled={!onMoveUp} onClick={onMoveUp}>
            <ArrowUp className="size-5" />
          </Button>
          <Button aria-label="Move detail down" disabled={!onMoveDown} onClick={onMoveDown}>
            <ArrowDown className="size-5" />
          </Button>
        </>
      ) : null}
      <Button onClick={onDelete}>
        <Trash className="size-5" />
      </Button>
    </div>
  </div>
);
