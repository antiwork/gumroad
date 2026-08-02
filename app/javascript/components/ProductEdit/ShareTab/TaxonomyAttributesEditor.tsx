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
  setValues,
}: {
  attributes: TaxonomyAttribute[];
  values: Record<string, TaxonomyAttributeValue>;
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
      {attributes.map((attribute) => (
        <Label key={attribute.name} className="w-full">
          {attribute.label}
          <AttributeInput
            attribute={attribute}
            value={values[attribute.name]}
            onChange={(value) => updateValue(attribute.name, value)}
          />
        </Label>
      ))}
    </Fieldset>
  );
};

const AttributeInput = ({
  attribute,
  value,
  onChange,
}: {
  attribute: TaxonomyAttribute;
  value: TaxonomyAttributeValue | undefined;
  onChange: (value: TaxonomyAttributeValue) => void;
}) => {
  switch (attribute.value_type) {
    case "enum":
      return (
        <Select value={typeof value === "string" ? value : ""} onChange={(event) => onChange(event.target.value)}>
          <option value="">Select</option>
          {attribute.values.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </Select>
      );
    case "boolean":
      return (
        <Switch checked={value === true || value === "true"} onChange={(event) => onChange(event.target.checked)} />
      );
    case "number":
      return (
        <Input
          type="number"
          min="0"
          value={typeof value === "number" || typeof value === "string" ? value : ""}
          onChange={(event) => onChange(event.target.value === "" ? null : Number(event.target.value))}
        />
      );
  }
};
