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

  // Rows are keyed by position, so a reorder reuses the DOM nodes in place: the button the seller
  // just pressed stays where it was and now belongs to whichever detail slid into that slot, so a
  // second Enter moves that detail instead of the one they were moving. Remember where the moved
  // detail landed and put focus back on its own button after the update, so repeated presses keep
  // moving the same detail.
  const moveButtonsRef = React.useRef(
    new Map<number, { up: HTMLButtonElement | null; down: HTMLButtonElement | null }>(),
  );
  const focusAfterMoveRef = React.useRef<{ index: number; direction: "up" | "down" } | null>(null);

  const registerMoveButton = (idx: number, direction: "up" | "down", button: HTMLButtonElement | null) => {
    if (!button) return;
    const entry = moveButtonsRef.current.get(idx) ?? { up: null, down: null };
    entry[direction] = button;
    moveButtonsRef.current.set(idx, entry);
  };

  React.useEffect(() => {
    const pending = focusAfterMoveRef.current;
    if (!pending) return;
    focusAfterMoveRef.current = null;
    const entry = moveButtonsRef.current.get(pending.index);
    const sameDirection = pending.direction === "up" ? entry?.up : entry?.down;
    const otherDirection = pending.direction === "up" ? entry?.down : entry?.up;
    // The detail has reached the end of the list, where the button for the direction just used is
    // disabled and a disabled button cannot take focus; its other button still belongs to the same
    // row, so focus stays with the moved detail either way.
    const target = sameDirection && !sameDirection.disabled ? sameDirection : otherDirection;
    if (target && !target.disabled) target.focus();
  }, [customAttributes]);

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
    focusAfterMoveRef.current = { index: to, direction: to < idx ? "up" : "down" };
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
              registerMoveUp={(button) => registerMoveButton(idx, "up", button)}
              registerMoveDown={(button) => registerMoveButton(idx, "down", button)}
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
  registerMoveUp,
  registerMoveDown,
}: {
  attribute: Attribute;
  nameSuggestionsId?: string;
  onUpdate?: (update: Partial<Attribute>) => void;
  onDelete: () => void;
  onMoveUp?: (() => void) | undefined;
  onMoveDown?: (() => void) | undefined;
  registerMoveUp?: (button: HTMLButtonElement | null) => void;
  registerMoveDown?: (button: HTMLButtonElement | null) => void;
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
          <Button aria-label="Move detail up" ref={registerMoveUp} disabled={!onMoveUp} onClick={onMoveUp}>
            <ArrowUp className="size-5" />
          </Button>
          <Button aria-label="Move detail down" ref={registerMoveDown} disabled={!onMoveDown} onClick={onMoveDown}>
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
