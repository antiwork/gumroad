import * as React from "react";

import { TaxonomyAttribute, TaxonomyAttributeValue } from "$app/components/ProductEdit/state";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Switch } from "$app/components/ui/Switch";

export const TaxonomyAttributesEditor = ({
  attributes,
  values,
  inferredValues,
  setValues,
}: {
  attributes: TaxonomyAttribute[];
  values: Record<string, TaxonomyAttributeValue>;
  inferredValues: Record<string, TaxonomyAttributeValue>;
  setValues: (values: Record<string, TaxonomyAttributeValue>) => void;
}) => {
  if (attributes.length === 0) return null;

  const updateValue = (name: string, value: TaxonomyAttributeValue) =>
    setValues({
      ...values,
      [name]: value,
    });

  return (
    <Fieldset>
      <FieldsetTitle>Structured attributes</FieldsetTitle>
      <FieldsetDescription>These power category-specific filters in Discover.</FieldsetDescription>
      {attributes.map((attribute) => {
        // An inferred value with no explicit seller answer is displayed but not yet "theirs" —
        // editing it here writes to `values`, which always wins over the inferred one server-side
        // (gumroad-private#1788: "seller-visible and correctable").
        const hasExplicitValue = values[attribute.name] !== undefined;
        const displayValue = hasExplicitValue ? values[attribute.name] : inferredValues[attribute.name];

        return (
          <AttributeField
            key={attribute.name}
            attribute={attribute}
            value={displayValue}
            isInferred={!hasExplicitValue && inferredValues[attribute.name] !== undefined}
            onChange={(value) => updateValue(attribute.name, value)}
          />
        );
      })}
    </Fieldset>
  );
};

const AttributeField = ({
  attribute,
  value,
  isInferred,
  onChange,
}: {
  attribute: TaxonomyAttribute;
  value: TaxonomyAttributeValue | undefined;
  isInferred: boolean;
  onChange: (value: TaxonomyAttributeValue) => void;
}) => {
  const uid = React.useId();
  const inferredNote = isInferred ? (
    <span className="text-muted-foreground text-sm">Detected automatically — edit to correct it</span>
  ) : null;

  // A Switch carries its own label, so wrapping it in a Label would nest two labels for one control.
  if (attribute.value_type === "boolean") {
    return (
      <div className="grid gap-1">
        <Switch
          checked={value === true || value === "true"}
          onChange={(event) => onChange(event.target.checked)}
          label={attribute.label}
        />
        {inferredNote}
      </div>
    );
  }

  // Label above, full-width control below — same shape as the Category select directly above this
  // fieldset. An inline Label puts a short label beside a full-width input and wraps it mid-word.
  return (
    <div className="grid gap-2">
      <Label htmlFor={uid}>{attribute.label}</Label>
      {attribute.value_type === "enum" ? (
        <Select
          id={uid}
          value={typeof value === "string" ? value : ""}
          onChange={(event) => onChange(event.target.value)}
        >
          <option value="">Select</option>
          {attribute.values.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </Select>
      ) : (
        <Input
          id={uid}
          type="number"
          min="0"
          value={typeof value === "number" || typeof value === "string" ? value : ""}
          onChange={(event) => onChange(event.target.value === "" ? null : Number(event.target.value))}
        />
      )}
      {inferredNote}
    </div>
  );
};
