import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { Version, useProductEditContext } from "$app/components/ProductEdit/state";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Toggle } from "$app/components/Toggle";
import { WithTooltip } from "$app/components/WithTooltip";

let newVersionId = 0;

export const VersionsEditor = ({
  versions,
  onChange,
}: {
  versions: Version[];
  onChange: (versions: Version[]) => void;
}) => {
  const updateVersion = (id: string, update: Partial<Version>) => {
    onChange(versions.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  const [deletionModalVersionId, setDeletionModalVersionId] = React.useState<string | null>(null);
  const deletionModalVersion = versions.find(({ id }) => id === deletionModalVersionId);

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...versions,
          {
            id: (newVersionId++).toString(),
            name: "Untitled",
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
    >
      <Icon name="plus" />
      Add version
    </Button>
  );

  return versions.length === 0 ? (
    <div className="placeholder">
      <h2>Offer variations of this product</h2>
      Sweeten the deal for your customers with different options for format, version, etc
      {addButton}
    </div>
  ) : (
    <>
      {deletionModalVersion ? (
        <Modal
          open={!!deletionModalVersion}
          onClose={() => setDeletionModalVersionId(null)}
          title={`Remove ${deletionModalVersion.name}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalVersionId(null)}>No, cancel</Button>
              <Button
                color="accent"
                onClick={() => onChange(versions.filter(({ id }) => id !== deletionModalVersion.id))}
              >
                Yes, remove
              </Button>
            </>
          }
        >
          If you delete this version, its associated content will be removed as well. Your existing customers who
          purchased it will see the content from the current cheapest version as a fallback. If no version exists, they
          will see the product-level content.
        </Modal>
      ) : null}
      <SortableList
        currentOrder={versions.map(({ id }) => id)}
        onReorder={(newOrder) =>
          onChange(newOrder.flatMap((id) => versions.find((version) => version.id === id) ?? []))
        }
        tag={SortableVersionEditors}
      >
        {versions.map((version) => (
          <VersionEditor
            key={version.id}
            version={version}
            updateVersion={(update) => updateVersion(version.id, update)}
            onDelete={() => setDeletionModalVersionId(version.id)}
          />
        ))}
      </SortableList>
      {addButton}
    </>
  );
};

const VersionEditor = ({
  version,
  updateVersion,
  onDelete,
}: {
  version: Version;
  updateVersion: (update: Partial<Version>) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const { product, currencyType } = useProductEditContext();

  const [isOpen, setIsOpen] = React.useState(true);

  const url = useProductUrl({ option: version.id });

  const integrations = Object.entries(product.integrations)
    .filter(([_, enabled]) => enabled)
    .map(([name]) => name);

  return (
    <div role="listitem">
      <div className="content">
        <ReorderingHandle />
        <Icon name="stack-fill" />
        <h3>{version.name || "Untitled"}</h3>
      </div>
      <div className="actions">
        <WithTooltip tip={isOpen ? "Close drawer" : "Open drawer"}>
          <Button onClick={() => setIsOpen((prevIsOpen) => !prevIsOpen)}>
            <Icon name={isOpen ? "outline-cheveron-up" : "outline-cheveron-down"} />
          </Button>
        </WithTooltip>
        <WithTooltip tip="Remove">
          <Button onClick={onDelete} aria-label="Remove version">
            <Icon name="trash2" />
          </Button>
        </WithTooltip>
      </div>
      {isOpen ? (
        <Drawer className="grid gap-6">
          <fieldset>
            <label htmlFor={`${uid}-name`}>Name</label>
            <div className="input">
              <input
                id={`${uid}-name`}
                type="text"
                value={version.name}
                placeholder="Version name"
                onChange={(evt) => updateVersion({ name: evt.target.value })}
              />
              <a href={url} target="_blank" rel="noreferrer">
                Share
              </a>
            </div>
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}-description`}>Description</label>
            <textarea
              id={`${uid}-description`}
              value={version.description}
              onChange={(evt) => updateVersion({ description: evt.target.value })}
            />
          </fieldset>
          <section style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", alignItems: "flex-end" }}>
            <fieldset>
              <label htmlFor={`${uid}-price`}>Additional amount</label>
              <PriceInput
                id={`${uid}-price`}
                currencyCode={currencyType}
                cents={version.price_difference_cents}
                onChange={(price_difference_cents) => updateVersion({ price_difference_cents })}
                placeholder="0"
              />
            </fieldset>
            <fieldset>
              <label htmlFor={`${uid}-max-purchase-count`}>Maximum number of purchases</label>
              <NumberInput
                onChange={(value) => updateVersion({ max_purchase_count: value })}
                value={version.max_purchase_count}
              >
                {(inputProps) => (
                  <input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />
                )}
              </NumberInput>
            </fieldset>
          </section>
          {integrations.length > 0 ? (
            <fieldset>
              <legend>Integrations</legend>
              {integrations.map((integration) => (
                <Toggle
                  value={version.integrations[integration]}
                  onChange={(enabled) =>
                    updateVersion({ integrations: { ...version.integrations, [integration]: enabled } })
                  }
                  key={integration}
                >
                  {integration === "circle" ? "Enable access to Circle community" : "Enable access to Discord server"}
                </Toggle>
              ))}
            </fieldset>
          ) : null}
        </Drawer>
      ) : null}
    </div>
  );
};

export const SortableVersionEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <div ref={ref} className="rows" role="list" aria-label="Version editor">
      {children}
    </div>
  ),
);
SortableVersionEditors.displayName = "SortableVersionEditors";
