import React from "react";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import cx from "classnames";
import { type DiscountCollection } from "$app/data/discount_collection";

type DiscountCollectionFormProps = {
  title: string;
  submitLabel: string;
  collection?: DiscountCollection | null;
  cancel: () => void;
  save: (collection: {
    name: string;
    description: string;
    default_discount_type?: "percent" | "cents";
    default_discount_value?: number;
    default_max_purchase_count?: number;
    default_valid_at?: string;
    default_expires_at?: string;
    default_minimum_quantity?: number;
    default_duration_in_billing_cycles?: number;
    default_minimum_amount_cents?: number;
  }) => void;
  isLoading: boolean;
};

const DiscountCollectionForm = ({
  title,
  submitLabel,
  collection,
  cancel,
  save,
  isLoading,
}: DiscountCollectionFormProps) => {
  const [name, setName] = React.useState<{ value: string; error?: boolean }>({ value: collection?.name ?? "" });
  const [description, setDescription] = React.useState<{ value: string; error?: boolean }>({ value: collection?.description ?? "" });

  // Default parameters
  const [hasDefaults, setHasDefaults] = React.useState(!!collection?.has_defaults);
  const [defaultDiscountType, setDefaultDiscountType] = React.useState<"percent" | "cents">(collection?.defaults?.discount_type ?? "percent");
  const [defaultDiscountValue, setDefaultDiscountValue] = React.useState<{ value: number; error?: boolean }>({
    value: collection?.defaults?.discount_value ?? 10
  });
  const [defaultMaxPurchaseCount, setDefaultMaxPurchaseCount] = React.useState<{ value: number | null; error?: boolean }>({
    value: collection?.defaults?.max_purchase_count ?? null
  });
  const [defaultValidAt, setDefaultValidAt] = React.useState(collection?.defaults?.valid_at ?? "");
  const [defaultExpiresAt, setDefaultExpiresAt] = React.useState(collection?.defaults?.expires_at ?? "");
  const [defaultMinimumQuantity, setDefaultMinimumQuantity] = React.useState<{ value: number | null; error?: boolean }>({
    value: collection?.defaults?.minimum_quantity ?? null
  });
  const [defaultMinimumAmountCents, setDefaultMinimumAmountCents] = React.useState<{ value: number | null; error?: boolean }>({
    value: collection?.defaults?.minimum_amount_cents ?? null
  });
  const [defaultDurationInBillingCycles, setDefaultDurationInBillingCycles] = React.useState<{ value: number | null; error?: boolean }>({
    value: collection?.defaults?.duration_in_billing_cycles ?? null
  });

  const uid = React.useId();

  const handleSubmit = () => {
    if (name.value === "") {
      setName((prevName) => ({ ...prevName, error: true }));
      return;
    }

    const saveData: any = {
      name: name.value,
      description: description.value || "",
    };

    if (hasDefaults) {
      saveData.default_discount_type = defaultDiscountType;
      saveData.default_discount_value = defaultDiscountValue.value;
      saveData.default_max_purchase_count = defaultMaxPurchaseCount.value;
      saveData.default_valid_at = defaultValidAt || null;
      saveData.default_expires_at = defaultExpiresAt || null;
      saveData.default_minimum_quantity = defaultMinimumQuantity.value;
      saveData.default_minimum_amount_cents = defaultMinimumAmountCents.value;
      saveData.default_duration_in_billing_cycles = defaultDurationInBillingCycles.value;
    }

    save(saveData);
  };

  return (
    <main>
      <header>
        <h1>{title}</h1>
        <div className="actions">
          <Button onClick={cancel} disabled={isLoading}>
            <Icon name="x-square" />
            Cancel
          </Button>
          <Button color="accent" onClick={handleSubmit} disabled={isLoading}>
            {submitLabel}
          </Button>
        </div>
      </header>
      <form>
        <section>
          <header>
            <div className="paragraphs">
              <div>Create a collection to organize your discount codes and generate multiple codes at once.</div>
              <div>
                Collections help you manage related discount codes together, making it easier to track performance and create bulk codes for events or campaigns.
              </div>
              <a data-helper-prompt="How do I create discount collections?">Learn more</a>
            </div>
          </header>
          <fieldset className={cx({ danger: name.error })}>
            <legend>
              <label htmlFor={`${uid}name`}>Collection name</label>
            </legend>
            <input
              type="text"
              id={`${uid}name`}
              placeholder="Black Friday 2024"
              value={name.value}
              onChange={(evt) => setName({ value: evt.target.value })}
              aria-invalid={name.error}
            />
          </fieldset>
          <fieldset className={cx({ danger: description.error })}>
            <legend>
              <label htmlFor={`${uid}description`}>Description (optional)</label>
            </legend>
            <textarea
              id={`${uid}description`}
              placeholder="Describe what this collection is for..."
              value={description.value}
              onChange={(evt) => setDescription({ value: evt.target.value })}
              rows={3}
              aria-invalid={description.error}
            />
          </fieldset>

          <fieldset>
            <legend>
              <label>
                <input
                  type="checkbox"
                  checked={hasDefaults}
                  onChange={(evt) => setHasDefaults(evt.target.checked)}
                />
                Set default discount parameters for quick code creation
              </label>
            </legend>
            {hasDefaults && (
              <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Discount Type</label>
                  <select
                    value={defaultDiscountType}
                    onChange={(evt) => setDefaultDiscountType(evt.target.value as "percent" | "cents")}
                  >
                    <option value="percent">Percentage</option>
                    <option value="cents">Fixed Amount (cents)</option>
                  </select>
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Discount Value</label>
                  <input
                    type="number"
                    value={defaultDiscountValue.value}
                    onChange={(evt) => setDefaultDiscountValue({ value: parseFloat(evt.target.value) || 0 })}
                    min="0"
                    step={defaultDiscountType === "percent" ? "1" : "1"}
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Max Purchase Count (optional)</label>
                  <input
                    type="number"
                    value={defaultMaxPurchaseCount.value || ""}
                    onChange={(evt) => setDefaultMaxPurchaseCount({ value: evt.target.value ? parseInt(evt.target.value) : null })}
                    min="1"
                    placeholder="No limit"
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Valid From (optional)</label>
                  <input
                    type="date"
                    value={defaultValidAt}
                    onChange={(evt) => setDefaultValidAt(evt.target.value)}
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Expires At (optional)</label>
                  <input
                    type="date"
                    value={defaultExpiresAt}
                    onChange={(evt) => setDefaultExpiresAt(evt.target.value)}
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Minimum Quantity (optional)</label>
                  <input
                    type="number"
                    value={defaultMinimumQuantity.value || ""}
                    onChange={(evt) => setDefaultMinimumQuantity({ value: evt.target.value ? parseInt(evt.target.value) : null })}
                    min="1"
                    placeholder="No minimum"
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Minimum Amount (cents, optional)</label>
                  <input
                    type="number"
                    value={defaultMinimumAmountCents.value || ""}
                    onChange={(evt) => setDefaultMinimumAmountCents({ value: evt.target.value ? parseInt(evt.target.value) : null })}
                    min="0"
                    placeholder="No minimum"
                  />
                </div>

                <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                  <label>Duration in Billing Cycles (optional)</label>
                  <input
                    type="number"
                    value={defaultDurationInBillingCycles.value || ""}
                    onChange={(evt) => setDefaultDurationInBillingCycles({ value: evt.target.value ? parseInt(evt.target.value) : null })}
                    min="1"
                    placeholder="No duration"
                  />
                </div>
              </div>
            )}
          </fieldset>
        </section>
      </form>
    </main>
  );
};

export { DiscountCollectionForm };
