import { Editor } from "@tiptap/core";
import cx from "classnames";
import { format } from "date-fns";
import * as React from "react";

import { sendSamplePriceChangeEmail } from "$app/data/membership_tiers";
import { getIsSingleUnitCurrency } from "$app/utils/currency";
import { priceCentsToUnit } from "$app/utils/price";
import {
  numberOfMonthsInRecurrence,
  RecurrenceId,
  perRecurrenceLabels,
  recurrenceNames,
} from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { DateInput } from "$app/components/DateInput";
import { Details } from "$app/components/Details";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { RecurrencePriceValue, Tier, useProductEditContext } from "$app/components/ProductEdit/state";
import { RichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Toggle } from "$app/components/Toggle";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

let newTierId = 0;

export const TiersEditor = ({ tiers, onChange }: { tiers: Tier[]; onChange: (tiers: Tier[]) => void }) => {
  const updateVersion = (id: string, update: Partial<Tier>) => {
    onChange(tiers.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  const [deletionModalVersionId, setDeletionModalVersionId] = React.useState<string | null>(null);
  const deletionModalVersion = tiers.find(({ id }) => id === deletionModalVersionId);

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...tiers,
          {
            id: (newTierId++).toString(),
            name: "Untitled",
            description: "",
            max_purchase_count: null,
            customizable_price: false,
            apply_price_changes_to_existing_memberships: false,
            subscription_price_change_effective_date: null,
            subscription_price_change_message: null,
            recurrence_price_values: {
              monthly: { enabled: false },
              quarterly: { enabled: false },
              biannually: { enabled: false },
              yearly: { enabled: false },
              every_two_years: { enabled: false },
            },
            integrations: { discord: false, circle: false, google_calendar: false },
            newlyAdded: true,
            rich_content: [],
          },
        ]);
      }}
    >
      <Icon name="plus" />
      Add tier
    </Button>
  );

  return tiers.length === 0 ? (
    <div className="placeholder">
      <h2>Offer different tiers of this membership</h2>
      Sweeten the deal for your customers with different levels of access. Every membership needs at least one tier.
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
              <Button color="accent" onClick={() => onChange(tiers.filter(({ id }) => id !== deletionModalVersion.id))}>
                Yes, remove
              </Button>
            </>
          }
        >
          If you delete this tier, its associated content will be removed as well. Your existing customers who purchased
          it will see the content from the current cheapest tier as a fallback. If no tier exists, they will see the
          product-level content.
        </Modal>
      ) : null}
      <SortableList
        currentOrder={tiers.map(({ id }) => id)}
        onReorder={(newOrder) => onChange(newOrder.flatMap((id) => tiers.find((version) => version.id === id) ?? []))}
        tag={SortableTierEditors}
      >
        {tiers.map((version) => (
          <TierEditor
            key={version.id}
            tier={version}
            updateTier={(update) => updateVersion(version.id, update)}
            onDelete={() => setDeletionModalVersionId(version.id)}
          />
        ))}
      </SortableList>
      {addButton}
    </>
  );
};

const PLACEHOLDER_VALUES = { monthly: "5", quarterly: "15", biannually: "30", yearly: "60", every_two_years: "120" };

const TierEditor = ({
  tier,
  updateTier,
  onDelete,
}: {
  tier: Tier;
  updateTier: (update: Partial<Tier>) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const { product, currencyType } = useProductEditContext();

  const [isOpen, setIsOpen] = React.useState(true);

  const url = useProductUrl({ option: tier.id });

  const updateRecurrencePriceValue = (recurrence: RecurrenceId, update: Partial<RecurrencePriceValue>) =>
    updateTier({
      recurrence_price_values: {
        ...tier.recurrence_price_values,
        [recurrence]: { ...tier.recurrence_price_values[recurrence], ...update },
      },
    });

  const defaultRecurrencePriceValue = product.subscription_duration
    ? tier.recurrence_price_values[product.subscription_duration]
    : null;
  React.useEffect(() => {
    if (product.subscription_duration) {
      if (defaultRecurrencePriceValue?.price_cents) {
        const defaultPriceProratedPerMonth =
          defaultRecurrencePriceValue.price_cents / numberOfMonthsInRecurrence(product.subscription_duration);
        updateTier({
          recurrence_price_values: Object.fromEntries(
            Object.entries(tier.recurrence_price_values).map(([r, v]) => [
              r,
              {
                ...v,
                price_cents: v.enabled ? v.price_cents : defaultPriceProratedPerMonth * numberOfMonthsInRecurrence(r),
              },
            ]),
          ),
        });
      }
    }
  }, [defaultRecurrencePriceValue?.price_cents]);

  const integrations = Object.entries(product.integrations)
    .filter(([_, enabled]) => enabled)
    .map(([name]) => name);

  return (
    <div role="listitem">
      <div className="content">
        <ReorderingHandle />
        <Icon name="stack-fill" />
        <div>
          <h3>{tier.name || "Untitled"}</h3>
          {tier.active_subscribers_count ? (
            <small>
              {tier.active_subscribers_count} {tier.active_subscribers_count === 1 ? "supporter" : "supporters"}
            </small>
          ) : null}
        </div>
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
            <label htmlFor={`${uid}-name`}>Name</label>
            <div className="input">
              <input
                id={`${uid}-name`}
                type="text"
                value={tier.name}
                onChange={(evt) => updateTier({ name: evt.target.value })}
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
              value={tier.description}
              onChange={(evt) => updateTier({ description: evt.target.value })}
            />
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}-max-purchase-count`}>Maximum number of active supporters</label>
            <NumberInput
              onChange={(value) => updateTier({ max_purchase_count: value })}
              value={tier.max_purchase_count}
            >
              {(inputProps) => <input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />}
            </NumberInput>
          </fieldset>
          <fieldset
            style={{
              display: "grid",
              gap: "var(--spacer-3)",
              gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
            }}
          >
            <legend>Pricing</legend>
            {Object.entries(tier.recurrence_price_values).map(([recurrence, value]) => (
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "max-content 1fr",
                  alignItems: "center",
                  gap: "var(--spacer-2)",
                }}
                key={recurrence}
              >
                <input
                  type="checkbox"
                  role="switch"
                  checked={value.enabled}
                  aria-label={`Toggle recurrence option: ${recurrenceNames[recurrence]}`}
                  onChange={() => updateRecurrencePriceValue(recurrence, { enabled: !value.enabled })}
                />
                <PriceInput
                  id={`${uid}-price`}
                  currencyCode={currencyType}
                  cents={value.price_cents ?? null}
                  onChange={(price_cents) => updateRecurrencePriceValue(recurrence, { price_cents })}
                  placeholder={PLACEHOLDER_VALUES[recurrence]}
                  suffix={perRecurrenceLabels[recurrence]}
                  disabled={!value.enabled}
                  ariaLabel={`Amount ${perRecurrenceLabels[recurrence]}`}
                />
              </div>
            ))}
          </fieldset>
          <Details
            summary={
              <Toggle
                value={tier.customizable_price}
                onChange={(customizable_price) => updateTier({ customizable_price })}
              >
                Allow customers to pay what they want
              </Toggle>
            }
            className="toggle"
            open={tier.customizable_price}
          >
            <div className="dropdown">
              <div
                style={{
                  display: "grid",
                  gap: "var(--spacer-3)",
                  gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
                }}
              >
                {Object.entries(tier.recurrence_price_values).flatMap(([recurrence, value]) =>
                  value.enabled ? (
                    <React.Fragment key={recurrence}>
                      <fieldset>
                        <label htmlFor={`${uid}-${recurrence}-minimum-price`}>
                          Minimum amount {perRecurrenceLabels[recurrence]}
                        </label>
                        <PriceInput
                          id={`${uid}-${recurrence}-minimum-price`}
                          currencyCode={currencyType}
                          cents={value.price_cents}
                          disabled
                        />
                      </fieldset>
                      <fieldset>
                        <label htmlFor={`${uid}-${recurrence}-suggested-price`}>
                          Suggested amount {perRecurrenceLabels[recurrence]}
                        </label>
                        <PriceInput
                          id={`${uid}-${recurrence}-suggested-price`}
                          currencyCode={currencyType}
                          cents={value.suggested_price_cents}
                          onChange={(suggested_price_cents) =>
                            updateRecurrencePriceValue(recurrence, { suggested_price_cents })
                          }
                          placeholder={PLACEHOLDER_VALUES[recurrence]}
                        />
                      </fieldset>
                    </React.Fragment>
                  ) : (
                    []
                  ),
                )}
              </div>
            </div>
          </Details>
          <PriceChangeSettings tier={tier} updateTier={updateTier} />
          {integrations.length > 0 ? (
            <fieldset>
              <legend>Integrations</legend>
              {integrations.map((integration) => (
                <Toggle
                  value={tier.integrations[integration]}
                  onChange={(enabled) => updateTier({ integrations: { ...tier.integrations, [integration]: enabled } })}
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

const getDateWithUTCOffset = (date: Date): Date => new Date(date.getTime() + date.getTimezoneOffset() * 60 * 1000);
const PriceChangeSettings = ({ tier, updateTier }: { tier: Tier; updateTier: (update: Partial<Tier>) => void }) => {
  const uid = React.useId();

  const [isMounted, setIsMounted] = React.useState(false);
  useRunOnce(() => setIsMounted(true));

  const { product, uniquePermalink, currencyType, earliestMembershipPriceChangeDate } = useProductEditContext();

  const [effectiveDate, setEffectiveDate] = React.useState<{ value: Date; error?: boolean }>({
    value: tier.subscription_price_change_effective_date
      ? new Date(tier.subscription_price_change_effective_date)
      : earliestMembershipPriceChangeDate,
  });
  effectiveDate.value = getDateWithUTCOffset(effectiveDate.value);
  React.useEffect(
    () => updateTier({ subscription_price_change_effective_date: effectiveDate.value.toISOString() }),
    [effectiveDate],
  );
  const [initialEffectiveDate] = React.useState(
    tier.subscription_price_change_effective_date
      ? getDateWithUTCOffset(new Date(tier.subscription_price_change_effective_date))
      : null,
  );

  const enabledPrice = Object.entries(tier.recurrence_price_values).find(([_, value]) => value.enabled);
  const newPrice = enabledPrice?.[1]?.enabled
    ? {
        recurrence: enabledPrice[0],
        amount: priceCentsToUnit(enabledPrice[1].price_cents ?? 0, getIsSingleUnitCurrency(currencyType)).toString(),
      }
    : { recurrence: "monthly" as const, amount: "10" };

  const [editorContent] = React.useState(tier.subscription_price_change_message);
  const [editor, setEditor] = React.useState<Editor | null>(null);

  const formattedEffectiveDate = format(effectiveDate.value, "yyyy-MM-dd");
  const placeholder = `The price of your membership to "${product.name}" is changing on ${formattedEffectiveDate}.

You can modify or cancel your membership at any time.`;

  React.useEffect(() => {
    if (editor) {
      editor.view.dispatch(editor.state.tr);
      const placeholderExtension = editor.extensionManager.extensions.find(({ name }) => name === "placeholder");
      if (placeholderExtension) {
        // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
        placeholderExtension.options.placeholder = placeholder;
        editor.view.dispatch(editor.state.tr);
      }
    }
  }, [placeholder, editor]);

  const onMessageChange = useDebouncedCallback((message: string) => {
    updateTier({ subscription_price_change_message: message });
  }, 500);

  return (
    <Details
      summary={
        <Toggle
          value={tier.apply_price_changes_to_existing_memberships}
          onChange={(apply_price_changes_to_existing_memberships) =>
            updateTier({
              apply_price_changes_to_existing_memberships,
              subscription_price_change_effective_date: effectiveDate.value.toISOString(),
            })
          }
        >
          Apply price changes to existing customers
        </Toggle>
      }
      className="toggle"
      open={tier.apply_price_changes_to_existing_memberships}
    >
      <div className="dropdown">
        <div className="override grid gap-6">
          {initialEffectiveDate ? (
            <div role="alert" className="warning">
              You have scheduled a pricing update for existing customers on {format(initialEffectiveDate, "MMMM d, y")}
            </div>
          ) : null}
          <div>
            <strong>
              We'll send an email reminder to your active members stating the new price 7 days prior to their next
              scheduled payment.
            </strong>{" "}
            <button
              type="button"
              className="link"
              onClick={() =>
                void sendSamplePriceChangeEmail({
                  productPermalink: uniquePermalink,
                  tierId: tier.id,
                  newPrice,
                  customMessage: tier.subscription_price_change_message,
                  effectiveDate: formattedEffectiveDate,
                }).then(
                  () => {
                    showAlert("Email sample sent! Check your email", "success");
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert("Error sending email", "error");
                  },
                )
              }
            >
              Get a sample
            </button>
          </div>
          <fieldset className={cx({ danger: effectiveDate.error })}>
            <legend>
              <label htmlFor={`${uid}-date`}>Effective date for existing customers</label>
            </legend>
            <DateInput
              id={`${uid}-date`}
              value={effectiveDate.value}
              onChange={(value) => {
                if (!value) return;
                setEffectiveDate({ value, error: value < earliestMembershipPriceChangeDate });
              }}
            />

            {effectiveDate.error ? <small>The effective date must be at least 7 days from today</small> : null}
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-custom-message`}>Custom message</label>
            </legend>
            {isMounted ? (
              <RichTextEditor
                id={`${uid}-custom-message`}
                className="textarea"
                placeholder={placeholder}
                ariaLabel="Custom message"
                initialValue={editorContent}
                onChange={onMessageChange}
                onCreate={setEditor}
              />
            ) : null}
          </fieldset>
        </div>
      </div>
    </Details>
  );
};

export const SortableTierEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <div ref={ref} className="rows" role="list" aria-label="Tier editor">
      {children}
    </div>
  ),
);
SortableTierEditors.displayName = "SortableTierEditors";
