import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { Duration, useProductEditContext } from "$app/components/ProductEdit/state";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { WithTooltip } from "$app/components/WithTooltip";

let newDurationId = 0;

export const DurationsEditor = ({
  durations,
  onChange,
}: {
  durations: Duration[];
  onChange: (durations: Duration[]) => void;
}) => {
  const updateDuration = (id: string, update: Partial<Duration>) => {
    onChange(durations.map((duration) => (duration.id === id ? { ...duration, ...update } : duration)));
  };

  const [deletionModalDurationId, setDeletionModalDurationId] = React.useState<string | null>(null);
  const deletionModalDuration = durations.find(({ id }) => id === deletionModalDurationId);

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...durations,
          {
            id: (newDurationId++).toString(),
            name: "Untitled",
            duration_in_minutes: null,
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
      Add duration
    </Button>
  );

  return durations.length === 0 ? (
    <div className="placeholder">
      <h2>Add duration</h2>
      Create one or more call durations for customers to choose from.
      {addButton}
    </div>
  ) : (
    <>
      {deletionModalDuration ? (
        <Modal
          open={!!deletionModalDuration}
          onClose={() => setDeletionModalDurationId(null)}
          title={`Remove ${deletionModalDuration.name}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalDurationId(null)}>No, cancel</Button>
              <Button
                color="accent"
                onClick={() => onChange(durations.filter(({ id }) => id !== deletionModalDuration.id))}
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
        currentOrder={durations.map(({ id }) => id)}
        onReorder={(newOrder) =>
          onChange(newOrder.flatMap((id) => durations.find((version) => version.id === id) ?? []))
        }
        tag={SortableDurationEditors}
      >
        {durations.map((duration) => (
          <DurationEditor
            key={duration.id}
            duration={duration}
            updateDuration={(update) => updateDuration(duration.id, update)}
            onDelete={() => setDeletionModalDurationId(duration.id)}
          />
        ))}
      </SortableList>
      {addButton}
    </>
  );
};

const DurationEditor = ({
  duration,
  updateDuration,
  onDelete,
}: {
  duration: Duration;
  updateDuration: (update: Partial<Duration>) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const { currencyType } = useProductEditContext();

  const [isOpen, setIsOpen] = React.useState(true);

  return (
    <div role="listitem">
      <div className="content">
        <ReorderingHandle />
        <Icon name="outline-clock" />
        <h3>{duration.name}</h3>
      </div>
      <div className="actions">
        <WithTooltip tip={isOpen ? "Close drawer" : "Open drawer"}>
          <Button onClick={() => setIsOpen((prevIsOpen) => !prevIsOpen)}>
            <Icon name={isOpen ? "outline-cheveron-up" : "outline-cheveron-down"} />
          </Button>
        </WithTooltip>
        <WithTooltip tip="Remove">
          <Button onClick={onDelete} aria-label="Remove">
            <Icon name="trash2" />
          </Button>
        </WithTooltip>
      </div>
      {isOpen ? (
        <Drawer className="override grid gap-6">
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-duration`}>Duration</label>
            </legend>
            <div className="input">
              <NumberInput
                value={duration.duration_in_minutes}
                onChange={(duration_in_minutes) =>
                  updateDuration({
                    duration_in_minutes,
                    name: duration_in_minutes
                      ? `${duration_in_minutes} ${duration_in_minutes === 1 ? "minute" : "minutes"}`
                      : "Untitled",
                  })
                }
              >
                {(props) => <input id={`${uid}-duration`} {...props} />}
              </NumberInput>
              <div className="pill">minutes</div>
            </div>
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}-description`}>Description</label>
            <textarea
              id={`${uid}-description`}
              value={duration.description}
              onChange={(evt) => updateDuration({ description: evt.target.value })}
            />
          </fieldset>
          <section style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", alignItems: "flex-end" }}>
            <fieldset>
              <label htmlFor={`${uid}-price`}>Additional amount</label>
              <PriceInput
                id={`${uid}-price`}
                currencyCode={currencyType}
                cents={duration.price_difference_cents}
                onChange={(price_difference_cents) => updateDuration({ price_difference_cents })}
                placeholder="0"
              />
            </fieldset>
            <fieldset>
              <label htmlFor={`${uid}-max-purchase-count`}>Maximum number of purchases</label>
              <NumberInput
                onChange={(value) => updateDuration({ max_purchase_count: value })}
                value={duration.max_purchase_count}
              >
                {(inputProps) => (
                  <input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />
                )}
              </NumberInput>
            </fieldset>
          </section>
        </Drawer>
      ) : null}
    </div>
  );
};

export const SortableDurationEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <div ref={ref} className="rows" role="list" aria-label="Duration editor">
      {children}
    </div>
  ),
);
SortableDurationEditors.displayName = "SortableDurationEditors";
