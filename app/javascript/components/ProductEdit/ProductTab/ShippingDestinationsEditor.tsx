import { Box, Plus, Trash } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
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
  excludedCountryCodes = [],
  onExcludedCountryCodesChange,
}: {
  shippingDestinations: ShippingDestination[];
  onChange: (shippingDestinations: ShippingDestination[]) => void;
  // Editor payloads rendered before exclusions existed omit the list. Defaulting here, not in the
  // product state, keeps an untouched save from sending an empty list over the saved one.
  excludedCountryCodes?: string[] | undefined;
  onExcludedCountryCodesChange: (excludedCountryCodes: string[]) => void;
}) => {
  const { availableCountries } = useProductEditContext();

  const excludableCountries = availableCountries.filter((country) => !EXCLUDED_ONLY_CODES.has(country.code));

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

  // Unlike a destination, a preselected exclusion would block buyers on Save without the seller choosing it.
  const addExcludedCountry = () => onExcludedCountryCodesChange([...excludedCountryCodes, ""]);

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
              <Plus className="size-5" />
              Add shipping destination
            </Button>
          </CardContent>
        </Card>
      ) : (
        <Placeholder>
          <h2>Add shipping destinations</h2>
          Choose where you're able to ship your physical product to
          <Button color="primary" onClick={addShippingDestination}>
            <Box className="size-5" />
            Add shipping destination
          </Button>
        </Placeholder>
      )}
      {shippingDestinations.length > 0 ? (
        <Card>
          <CardContent>
            <h3>Do not ship to</h3>
            <p>Buyers in these countries cannot buy this product, even where a destination above covers them.</p>
          </CardContent>
          {excludedCountryCodes.map((countryCode, index) => (
            <ShippingExclusionRow
              key={index}
              countryCode={countryCode}
              excludedCountryCodes={excludedCountryCodes}
              countries={excludableCountries}
              onChange={(updatedCountryCode) =>
                onExcludedCountryCodesChange([
                  ...excludedCountryCodes.slice(0, index),
                  updatedCountryCode,
                  ...excludedCountryCodes.slice(index + 1),
                ])
              }
              onRemove={() => onExcludedCountryCodesChange(excludedCountryCodes.filter((_, i) => i !== index))}
            />
          ))}
          {excludedCountryCodes.length < excludableCountries.length ? (
            <CardContent>
              <Button
                onClick={addExcludedCountry}
                className="grow basis-0"
                disabled={excludedCountryCodes.includes("")}
              >
                <Plus className="size-5" />
                Add excluded country
              </Button>
            </CardContent>
          ) : null}
        </Card>
      ) : null}
    </section>
  );
};

const ShippingExclusionRow = ({
  countryCode,
  excludedCountryCodes,
  countries,
  onChange,
  onRemove,
}: {
  countryCode: string;
  excludedCountryCodes: string[];
  countries: { code: string; name: string }[];
  onChange: (countryCode: string) => void;
  onRemove: () => void;
}) => {
  const uid = React.useId();

  return (
    <CardContent aria-label="Excluded shipping country">
      <Fieldset className="grow basis-0">
        <FieldsetTitle>
          <Label htmlFor={`${uid}-excluded-country`}>Country</Label>
        </FieldsetTitle>
        <div className="flex gap-2">
          <Select
            id={`${uid}-excluded-country`}
            aria-label="Excluded country"
            className="flex-1"
            value={countryCode}
            onChange={(evt) => onChange(evt.target.value)}
          >
            {countryCode === "" ? (
              <option value="" disabled>
                Choose a country
              </option>
            ) : null}
            {countries.map((country) => (
              <option
                key={country.code}
                value={country.code}
                disabled={country.code !== countryCode && excludedCountryCodes.includes(country.code)}
              >
                {country.name}
              </option>
            ))}
          </Select>
          <WithTooltip position="bottom" tip="Remove">
            <Button color="danger" size="icon" outline onClick={onRemove} aria-label="Remove excluded country">
              <Trash className="size-5" />
            </Button>
          </WithTooltip>
        </div>
      </Fieldset>
    </CardContent>
  );
};

const INSERT_DIVIDERS_AFTER_CODES = ["US", "NORTH AMERICA", "ELSEWHERE"];
// Regions and ELSEWHERE describe coverage; an exclusion names one concrete country.
const EXCLUDED_ONLY_CODES = new Set(["EUROPE", "ASIA", "NORTH AMERICA", "ELSEWHERE"]);

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
            <Button color="danger" size="icon" outline onClick={onRemove} aria-label="Remove shipping destination">
              <Trash className="size-5" />
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
