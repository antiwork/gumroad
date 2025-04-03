import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { PriceInput } from "$app/components/PriceInput";
import { Version, useProductEditContext } from "$app/components/ProductEdit/state";

let newVersionId = 0;

export const SuggestedAmountsEditor = ({
  versions,
  onChange,
}: {
  versions: Version[];
  onChange: (versions: Version[]) => void;
}) => {
  const updateVersion = (id: string, update: Partial<Version>) => {
    onChange(versions.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...versions,
          {
            id: (newVersionId++).toString(),
            name: "",
            description: "",
            price_difference_cents: 0,
            max_purchase_count: null,
            integrations: {
              discord: false,
              circle: false,
              google_calendar: false,
            },
            newlyAdded: true,
            rich_content: [],
          },
        ]);
      }}
      disabled={versions.length === 3}
    >
      <Icon name="plus" />
      Add amount
    </Button>
  );

  return (
    <fieldset>
      <legend>{versions.length > 1 ? "Suggested amounts" : "Suggested amount"}</legend>
      {versions.map((version, index) => (
        <SuggestedAmountEditor
          key={version.id}
          version={version}
          updateVersion={(update) => updateVersion(version.id, update)}
          onDelete={versions.length > 1 ? () => onChange(versions.filter(({ id }) => id !== version.id)) : null}
          label={`Suggested amount ${index + 1}`}
          onBlur={() =>
            onChange(versions.sort((a, b) => (a.price_difference_cents ?? 0) - (b.price_difference_cents ?? 0)))
          }
        />
      ))}
      {addButton}
    </fieldset>
  );
};

const SuggestedAmountEditor = ({
  version,
  updateVersion,
  onDelete,
  label,
  onBlur,
}: {
  version: Version;
  updateVersion: (update: Partial<Version>) => void;
  onDelete: (() => void) | null;
  label: string;
  onBlur: () => void;
}) => {
  const { currencyType } = useProductEditContext();

  return (
    <section style={{ display: "flex", gap: "var(--spacer-2)" }}>
      <PriceInput
        currencyCode={currencyType}
        cents={version.price_difference_cents}
        onChange={(price_difference_cents) => updateVersion({ price_difference_cents })}
        placeholder="0"
        ariaLabel={label}
        onBlur={onBlur}
      />
      <Button aria-label="Delete" onClick={onDelete ?? undefined} disabled={!onDelete}>
        <Icon name="trash2" />
      </Button>
    </section>
  );
};
