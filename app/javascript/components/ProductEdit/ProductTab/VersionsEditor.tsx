import { ChevronDown, ChevronUp, LayersAlt, Plus, Trash } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { Version, useProductEditContext } from "$app/components/ProductEdit/state";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, RowDetails, Rows } from "$app/components/ui/Rows";
import { Switch } from "$app/components/ui/Switch";
import { Textarea } from "$app/components/ui/Textarea";
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
      <Plus className="size-5" />
      Add version
    </Button>
  );

  return versions.length === 0 ? (
    <Placeholder>
      <h2>Offer variations of this product</h2>
      Sweeten the deal for your customers with different options for format, version, etc
      {addButton}
    </Placeholder>
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
    <Row role="listitem">
      <RowContent>
        <ReorderingHandle />
        <LayersAlt pack="filled" className="size-5" />
        <h3>{version.name || "Untitled"}</h3>
      </RowContent>
      <RowActions>
        <WithTooltip tip={isOpen ? "Close drawer" : "Open drawer"}>
          <Button size="icon" onClick={() => setIsOpen((prevIsOpen) => !prevIsOpen)}>
            {isOpen ? <ChevronUp className="size-5" /> : <ChevronDown className="size-5" />}
          </Button>
        </WithTooltip>
        <WithTooltip tip="Remove">
          <Button size="icon" onClick={onDelete} aria-label="Remove version">
            <Trash className="size-5" />
          </Button>
        </WithTooltip>
      </RowActions>
      {isOpen ? (
        <RowDetails asChild>
          <Drawer className="grid gap-6">
            <Fieldset>
              <Label htmlFor={`${uid}-name`}>Name</Label>
              <InputGroup>
                <Input
                  id={`${uid}-name`}
                  type="text"
                  value={version.name}
                  placeholder="Version name"
                  onChange={(evt) => updateVersion({ name: evt.target.value })}
                />
                <a href={url} target="_blank" rel="noreferrer">
                  Share
                </a>
              </InputGroup>
            </Fieldset>
            <Fieldset>
              <Label htmlFor={`${uid}-description`}>Description</Label>
              <Textarea
                id={`${uid}-description`}
                value={version.description}
                onChange={(evt) => updateVersion({ description: evt.target.value })}
              />
            </Fieldset>
            <section className="grid grid-flow-col items-end gap-6">
              <Fieldset>
                <Label htmlFor={`${uid}-price`}>Additional amount</Label>
                <PriceInput
                  id={`${uid}-price`}
                  currencyCode={currencyType}
                  cents={version.price_difference_cents}
                  onChange={(price_difference_cents) => updateVersion({ price_difference_cents })}
                  placeholder="0"
                />
              </Fieldset>
              <Fieldset>
                <Label htmlFor={`${uid}-max-purchase-count`}>Maximum number of purchases</Label>
                <NumberInput
                  onChange={(value) => updateVersion({ max_purchase_count: value })}
                  value={version.max_purchase_count}
                >
                  {(inputProps) => (
                    <Input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />
                  )}
                </NumberInput>
              </Fieldset>
            </section>
            {integrations.length > 0 ? (
              <Fieldset>
                <FieldsetTitle>Integrations</FieldsetTitle>
                {integrations.map((integration) => (
                  <Switch
                    checked={version.integrations[integration]}
                    onChange={(e) =>
                      updateVersion({ integrations: { ...version.integrations, [integration]: e.target.checked } })
                    }
                    key={integration}
                    label={
                      integration === "circle" ? "Enable access to Circle community" : "Enable access to Discord server"
                    }
                  />
                ))}
              </Fieldset>
            ) : null}
          </Drawer>
        </RowDetails>
      ) : null}
    </Row>
  );
};

export const SortableVersionEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <Rows ref={ref} role="list" aria-label="Version editor">
      {children}
    </Rows>
  ),
);
SortableVersionEditors.displayName = "SortableVersionEditors";
