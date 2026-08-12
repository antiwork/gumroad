import { Plus, Trash } from "@boxicons/react";
import * as React from "react";

import { confirmRemovedVariantPageDeletions } from "$app/data/product_save_contract";

import { Button } from "$app/components/Button";
import { PriceInput } from "$app/components/PriceInput";
import { Version, useProductEditContext } from "$app/components/ProductEdit/state";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";

let newVersionId = 0;

export const SuggestedAmountsEditor = ({
  versions,
  onChange,
}: {
  versions: Version[];
  onChange: (versions: Version[]) => void;
}) => {
  const { updateProduct } = useProductEditContext();
  const updateVersion = (id: string, update: Partial<Version>) => {
    onChange(versions.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  // Clicking the trash button here IS the seller's explicit deletion intent
  // (there's no separate confirmation modal for suggested amounts), so record
  // the id for the server-side wipe guard — a persisted suggested amount has a
  // custom price, which the guard treats as configuration worth protecting.
  const removeVersion = (version: Version) => {
    updateProduct((product) => {
      // Recorded even for a newly added version: an in-flight save may be
      // creating it right now, and reconciliation remaps the recorded id to
      // the canonical one. An id the server never learns is inert.
      product.confirmed_removed_variant_ids = [...(product.confirmed_removed_variant_ids ?? []), version.id];
      confirmRemovedVariantPageDeletions(product, version.rich_content);
    });
    onChange(versions.filter(({ id }) => id !== version.id));
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
      <Plus className="size-5" />
      Add amount
    </Button>
  );

  return (
    <Fieldset>
      <FieldsetTitle>{versions.length > 1 ? "Suggested amounts" : "Suggested amount"}</FieldsetTitle>
      {versions.map((version, index) => (
        <SuggestedAmountEditor
          key={version.id}
          version={version}
          updateVersion={(update) => updateVersion(version.id, update)}
          onDelete={versions.length > 1 ? () => removeVersion(version) : null}
          label={`Suggested amount ${index + 1}`}
          onBlur={() =>
            onChange(versions.sort((a, b) => (a.price_difference_cents ?? 0) - (b.price_difference_cents ?? 0)))
          }
        />
      ))}
      {addButton}
    </Fieldset>
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
    <section className="flex gap-2">
      <PriceInput
        currencyCode={currencyType}
        cents={version.price_difference_cents}
        onChange={(price_difference_cents) => updateVersion({ price_difference_cents })}
        placeholder="0"
        ariaLabel={label}
        onBlur={onBlur}
      />
      <Button aria-label="Delete" onClick={onDelete ?? undefined} disabled={!onDelete}>
        <Trash className="size-5" />
      </Button>
    </section>
  );
};
