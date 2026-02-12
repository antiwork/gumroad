import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { PriceInput } from "$app/components/PriceInput";
import { ShippingDestination, useProductEditContext } from "$app/components/ProductEdit/state";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Select } from "$app/components/ui/Select";
import { WithTooltip } from "$app/components/WithTooltip";

export const ShippingDestinationsEditor = ({
  shippingDestinations,
  onChange,
}: {
  shippingDestinations: ShippingDestination[];
  onChange: (shippingDestinations: ShippingDestination[]) => void;
}) => {
  const { availableCountries } = useProductEditContext();

  const addShippingDestination = () => {
    if (!availableCountries[0]) return;
    onChange([
      ...shippingDestinations,
      {
        country_code: availableCountries[0].code,
        one_item_rate_cents: null,
        multiple_items_rate_cents: null,
      },
    ]);
  };

  return (
    <section className="grid gap-8 border-t border-border p-4 md:p-8">
      <header>
        <h2>Shipping destinations</h2>
      </header>
      {shippingDestinations.length > 0 ? (
        <Card>
          {shippingDestinations.map((shippingDestination, index) => (
            <ShippingDestinationRow
              shippingDestination={shippingDestination}
              onChange={(updatedShippingDestination) =>
                onChange([
                  ...shippingDestinations.slice(0, index),
                  updatedShippingDestination,
                  ...shippingDestinations.slice(index + 1),
                ])
              }
              onRemove={() => onChange(shippingDestinations.filter((_, i) => i !== index))}
              key={index}
            />
          ))}
          <CardContent>
            <Button onClick={addShippingDestination} className="grow basis-0">
              <Icon name="plus" />
              Add shipping destination
            </Button>
          </CardContent>
        </Card>
      ) : (
        <Placeholder>
          <h2>Add shipping destinations</h2>
          Choose where you're able to ship your physical product to
          <Button color="primary" onClick={addShippingDestination}>
            <Icon name="box" />
            Add shipping destination
          </Button>
        </Placeholder>
      )}
    </section>
  );
};

const INSERT_DIVIDERS_AFTER_CODES = ["US", "NORTH AMERICA", "ELSEWHERE"];

const ShippingDestinationRow = ({
  shippingDestination,
  onChange,
  onRemove,
}: {
  shippingDestination: ShippingDestination;
  onChange: (shippingDestination: ShippingDestination) => void;
  onRemove: () => void;
}) => {
  const { availableCountries, currencyType } = useProductEditContext();
  const uid = React.useId();

  const updateDestination = (update: Partial<ShippingDestination>) => onChange({ ...shippingDestination, ...update });

  return (
    <CardContent aria-label="Shipping destination">
      <Fieldset className="grow basis-0">
        <FieldsetTitle>
          <Label htmlFor={`${uid}-country`}>Country</Label>
        </FieldsetTitle>
        <div className="flex gap-2">
          <Select
            id={`${uid}-country`}
            aria-label="Country"
            className="flex-1"
            value={shippingDestination.country_code}
            onChange={(evt) => updateDestination({ country_code: evt.target.value })}
          >
            {availableCountries.map((country) => {
              const shouldInsertDividerAfter = INSERT_DIVIDERS_AFTER_CODES.includes(country.code);

              return (
                <React.Fragment key={country.code}>
                  <option value={country.code}>{country.name}</option>
                  {shouldInsertDividerAfter ? <option disabled>──────────────</option> : null}
                </React.Fragment>
              );
            })}
          </Select>
          <WithTooltip position="bottom" tip="Remove">
            <Button color="danger" outline onClick={onRemove} aria-label="Remove shipping destination">
              <Icon name="trash2" />
            </Button>
          </WithTooltip>
        </div>
      </Fieldset>
      <div style={{ display: "grid", gridAutoFlow: "column", gap: "var(--spacer-3)", width: "100%" }}>
        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-one-item`}>Amount alone</Label>
          </FieldsetTitle>
          <PriceInput
            id={`${uid}-one-item`}
            currencyCode={currencyType}
            cents={shippingDestination.one_item_rate_cents}
            placeholder="0"
            onChange={(one_item_rate_cents) => updateDestination({ one_item_rate_cents })}
          />
        </Fieldset>
        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-multiple-items`}>Amount with others</Label>
          </FieldsetTitle>
          <PriceInput
            id={`${uid}-multiple-items`}
            currencyCode={currencyType}
            cents={shippingDestination.multiple_items_rate_cents}
            placeholder="0"
            onChange={(multiple_items_rate_cents) => updateDestination({ multiple_items_rate_cents })}
          />
        </Fieldset>
      </div>
    </CardContent>
  );
};
