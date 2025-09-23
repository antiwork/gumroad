import cx from "classnames";
import * as React from "react";
import { Link, useLoaderData, useNavigate, useRevalidator } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  WorkflowFormContext,
  Workflow,
  WorkflowType,
  createWorkflow,
  LegacyWorkflowTrigger,
  updateWorkflow,
  SaveActionName,
  ProductOption,
  VariantOption,
} from "$app/data/workflows";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import {
  Layout,
  EditPageNavigation,
  sendToPastCustomersCheckboxLabel,
  PublishButton,
} from "$app/components/server-components/WorkflowsPage";
import { TagInput } from "$app/components/TagInput";
import { WithTooltip } from "$app/components/WithTooltip";

import abandonedCartTriggerImage from "$assets/images/workflows/triggers/abandoned_cart.svg";
import audienceTriggerImage from "$assets/images/workflows/triggers/audience.svg";
import memberCancelsTriggerImage from "$assets/images/workflows/triggers/member_cancels.svg";
import newAffiliateTriggerImage from "$assets/images/workflows/triggers/new_affiliate.svg";
import newSubscriberTriggerImage from "$assets/images/workflows/triggers/new_subscriber.svg";
import purchaseTriggerImage from "$assets/images/workflows/triggers/purchase.svg";

// "legacy_audience" is for backwards compatibility and is only shown while editing an existing workflow of that type
export type WorkflowTrigger =
  | "legacy_audience"
  | "purchase"
  | "new_subscriber"
  | "member_cancels"
  | "new_affiliate"
  | "abandoned_cart";

export const determineWorkflowTrigger = (workflow: Workflow): WorkflowTrigger => {
  if (workflow.workflow_type === "abandoned_cart") return "abandoned_cart";
  if (workflow.workflow_type === "audience") return "legacy_audience";
  if (workflow.workflow_type === "follower") return "new_subscriber";
  if (workflow.workflow_type === "affiliate") return "new_affiliate";
  if (workflow.workflow_trigger === "member_cancellation") return "member_cancels";
  return "purchase";
};

const determineWorkflowType = (
  trigger: WorkflowTrigger,
  boughtItems: (ProductOption | VariantOption)[],
): WorkflowType => {
  if (trigger === "abandoned_cart") return "abandoned_cart";
  if (trigger === "legacy_audience") return "audience";
  if (trigger === "new_subscriber") return "follower";
  if (trigger === "new_affiliate") return "affiliate";
  if (boughtItems.length === 1) return boughtItems[0]?.type === "variant" ? "variant" : "product";
  return "seller";
};

const selectableProductAndVariantOptions = (
  options: WorkflowFormContext["products_and_variant_options"],
  alwaysIncludeIds: string[],
) => options.filter((o) => alwaysIncludeIds.includes(o.id) || !o.archived);

type WorkflowFormState = {
  name: string;
  trigger: WorkflowTrigger;
  sendToPastCustomers: boolean;
  affiliatedProducts: string[];
  bought: string[];
  notBought: string[];
  paidMoreThan: number | null;
  paidLessThan: number | null;
  afterDate: string;
  beforeDate: string;
  fromCountry: string;
};
const WorkflowForm = () => {
  const navigate = useNavigate();
  const { context, workflow } = cast<{ context: WorkflowFormContext; workflow?: Workflow }>(useLoaderData());
  const loaderDataRevalidator = useRevalidator();
  const wasPublishedPreviously = !!workflow?.first_published_at;
  const [formState, setFormState] = React.useState<WorkflowFormState>(() => {
    if (!workflow)
      return {
        name: "",
        trigger: "purchase",
        sendToPastCustomers: false,
        affiliatedProducts: [],
        bought: [],
        notBought: [],
        paidMoreThan: null,
        paidLessThan: null,
        afterDate: "",
        beforeDate: "",
        fromCountry: "",
      };

    const bought =
      workflow.workflow_type === "variant" && workflow.variant_external_id
        ? [workflow.variant_external_id]
        : workflow.workflow_type === "product" && workflow.unique_permalink
          ? [workflow.unique_permalink]
          : [...(workflow.bought_products ?? []), ...(workflow.bought_variants ?? [])];
    return {
      name: workflow.name,
      trigger: determineWorkflowTrigger(workflow),
      sendToPastCustomers: workflow.send_to_past_customers,
      affiliatedProducts: workflow.affiliate_products ?? [],
      bought,
      notBought: workflow.not_bought_products || workflow.not_bought_variants || [],
      paidMoreThan: workflow.paid_more_than ? parseInt(workflow.paid_more_than.replaceAll(",", ""), 10) : null,
      paidLessThan: workflow.paid_less_than ? parseInt(workflow.paid_less_than.replaceAll(",", ""), 10) : null,
      afterDate: workflow.created_after ?? "",
      beforeDate: workflow.created_before ?? "",
      fromCountry: workflow.bought_from ?? "",
    };
  });
  const [isSaving, setIsSaving] = React.useState(false);
  const [invalidFields, setInvalidFields] = React.useState<Set<keyof WorkflowFormState>>(() => new Set());
  const nameInputRef = React.useRef<HTMLInputElement>(null);
  const paidMoreThanInputRef = React.useRef<HTMLInputElement>(null);
  const afterDateInputRef = React.useRef<HTMLInputElement>(null);

  const triggerSupportsBoughtFilter = formState.trigger !== "legacy_audience" && formState.trigger !== "new_affiliate";
  const triggerSupportsNotBoughtFilter =
    formState.trigger === "legacy_audience" ||
    formState.trigger === "purchase" ||
    formState.trigger === "new_subscriber" ||
    formState.trigger === "abandoned_cart";
  const triggerSupportsDateFilters = formState.trigger !== "abandoned_cart";
  const triggerSupportsPaidFilters = formState.trigger === "purchase" || formState.trigger === "member_cancels";
  const triggerSupportsFromCountryFilter = formState.trigger === "purchase" || formState.trigger === "member_cancels";

  const updateFormState = (value: Partial<WorkflowFormState>) => {
    const updatedInvalidFields = new Set(invalidFields);

    Object.keys(value).forEach((field) => {
      if (!updatedInvalidFields.has(field)) return;
      if (field === "paidMoreThan" || field === "paidLessThan") {
        updatedInvalidFields.delete("paidMoreThan");
        updatedInvalidFields.delete("paidLessThan");
      } else if (field === "afterDate" || field === "beforeDate") {
        updatedInvalidFields.delete("afterDate");
        updatedInvalidFields.delete("beforeDate");
      } else {
        updatedInvalidFields.delete(field);
      }
    });

    setFormState((prev) => ({ ...prev, ...value }));
    setInvalidFields(updatedInvalidFields);
  };

  const validate = () => {
    const invalidFieldNames = new Set<keyof WorkflowFormState>();
    const invalidFieldRefs = [];

    if (formState.name.trim() === "") {
      invalidFieldNames.add("name");
      invalidFieldRefs.push(nameInputRef);
    }

    if (wasPublishedPreviously) return invalidFieldNames.size === 0;

    if (
      triggerSupportsPaidFilters &&
      formState.paidMoreThan &&
      formState.paidLessThan &&
      formState.paidMoreThan > formState.paidLessThan
    ) {
      invalidFieldNames.add("paidMoreThan");
      invalidFieldNames.add("paidLessThan");
      invalidFieldRefs.push(paidMoreThanInputRef);
    }

    if (
      triggerSupportsDateFilters &&
      formState.afterDate &&
      formState.beforeDate &&
      new Date(formState.afterDate) > new Date(formState.beforeDate)
    ) {
      invalidFieldNames.add("afterDate");
      invalidFieldNames.add("beforeDate");
      invalidFieldRefs.push(afterDateInputRef);
    }

    setInvalidFields(invalidFieldNames);

    invalidFieldRefs[0]?.current?.focus();

    return invalidFieldNames.size === 0;
  };

  const handleSave = asyncVoid(async (saveActionName: SaveActionName = "save") => {
    if (!validate()) return;

    const boughtItems = formState.bought.flatMap(
      (itemId) => context.products_and_variant_options.find(({ id }) => itemId === id) ?? [],
    );
    const workflowType = determineWorkflowType(formState.trigger, boughtItems);
    const workflowTrigger: LegacyWorkflowTrigger =
      formState.trigger === "member_cancels" ? "member_cancellation" : null;
    const productPermalink =
      workflowType === "product" || workflowType === "variant" ? (boughtItems[0]?.product_permalink ?? null) : null;
    const variantId = workflowType === "variant" ? (boughtItems[0]?.id ?? null) : null;
    const bought = triggerSupportsBoughtFilter
      ? boughtItems.reduce(
          (acc: { productIds: string[]; variantIds: string[] }, item) => {
            acc[item.type === "variant" ? "variantIds" : "productIds"].push(item.id);
            return acc;
          },
          { productIds: [], variantIds: [] },
        )
      : { productIds: [], variantIds: [] };
    const notBought = triggerSupportsNotBoughtFilter
      ? formState.notBought.reduce(
          (acc: { productIds: string[]; variantIds: string[] }, itemId) => {
            const item = context.products_and_variant_options.find(({ id }) => itemId === id);
            if (item) acc[item.type === "variant" ? "variantIds" : "productIds"].push(item.id);
            return acc;
          },
          { productIds: [], variantIds: [] },
        )
      : { productIds: [], variantIds: [] };
    const payload = {
      name: formState.name,
      workflow_type: workflowType,
      workflow_trigger: workflowTrigger,
      bought_products: bought.productIds,
      bought_variants: bought.variantIds,
      variant_external_id: variantId,
      permalink: productPermalink,
      not_bought_products: notBought.productIds,
      not_bought_variants: notBought.variantIds,
      paid_more_than: triggerSupportsPaidFilters ? formState.paidMoreThan : null,
      paid_less_than: triggerSupportsPaidFilters ? formState.paidLessThan : null,
      created_after: triggerSupportsDateFilters ? formState.afterDate : "",
      created_before: triggerSupportsDateFilters ? formState.beforeDate : "",
      bought_from: triggerSupportsFromCountryFilter ? formState.fromCountry : null,
      affiliate_products: formState.trigger === "new_affiliate" ? formState.affiliatedProducts : [],
      send_to_past_customers: formState.sendToPastCustomers,
      save_action_name: saveActionName,
    };

    try {
      setIsSaving(true);
      const response = await (workflow ? updateWorkflow(workflow.external_id, payload) : createWorkflow(payload));
      if (response.success) {
        if (saveActionName === "save") {
          showAlert("Changes saved!", "success");
          navigate(`/workflows/${response.workflow_id}/emails`);
        } else {
          showAlert(saveActionName === "save_and_publish" ? "Workflow published!" : "Unpublished!", "success");
          loaderDataRevalidator.revalidate();
        }
      } else {
        showAlert(response.message, "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setIsSaving(false);
    }
  });

  const abandonedCartButton = (
    <Button
      className="vertical"
      role="radio"
      disabled={wasPublishedPreviously || !context.eligible_for_abandoned_cart_workflows}
      aria-checked={formState.trigger === "abandoned_cart"}
      onClick={() => updateFormState({ trigger: "abandoned_cart" })}
    >
      <img src={abandonedCartTriggerImage} width={40} height={40} />
      <div>
        <h4>Abandoned cart</h4>A customer doesn't complete checking out
      </div>
    </Button>
  );

  return (
    <Layout
      title={workflow ? workflow.name : "New workflow"}
      navigation={workflow ? <EditPageNavigation workflowExternalId={workflow.external_id} /> : null}
      actions={
        <>
          <Link to="/workflows" className="button" inert={isSaving}>
            <Icon name="x-square" />
            Cancel
          </Link>
          <Button color="primary" onClick={() => handleSave()} disabled={isSaving}>
            {workflow ? "Save changes" : "Save and continue"}
          </Button>
          {workflow ? (
            <PublishButton
              isPublished={workflow.published}
              wasPublishedPreviously={wasPublishedPreviously}
              isDisabled={isSaving}
              sendToPastCustomers={
                formState.trigger === "abandoned_cart"
                  ? null
                  : {
                      enabled: formState.sendToPastCustomers,
                      toggle: (value) => updateFormState({ sendToPastCustomers: value }),
                      label: sendToPastCustomersCheckboxLabel(formState.trigger),
                    }
              }
              onClick={handleSave}
            />
          ) : null}
        </>
      }
    >
      <form className="space-y-4 p-4 md:p-8">
        <section>
          <header>Workflows allow you to send scheduled emails to a subset of your audience based on a trigger.</header>
          <fieldset className={cx({ danger: invalidFields.has("name") })}>
            <legend>
              <label htmlFor="name">Name</label>
            </legend>
            <input
              id="name"
              type="text"
              ref={nameInputRef}
              placeholder="Name of workflow"
              maxLength={255}
              value={formState.name}
              onChange={(e) => updateFormState({ name: e.target.value })}
            />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor="trigger">Trigger</label>
            </legend>
            <div
              className="radio-buttons"
              role="radiogroup"
              style={{
                gridTemplateColumns: "repeat(auto-fit, minmax(13rem, 1fr))",
              }}
            >
              {workflow && workflow.workflow_type === "audience" ? (
                <Button
                  className="vertical"
                  role="radio"
                  disabled={wasPublishedPreviously}
                  aria-checked={formState.trigger === "legacy_audience"}
                  onClick={() => updateFormState({ trigger: "legacy_audience" })}
                >
                  <img src={audienceTriggerImage} width={40} height={40} />
                  <div>
                    <h4>Audience</h4>A user becomes a customer, subscriber or an affiliate
                  </div>
                </Button>
              ) : null}
              <Button
                className="vertical"
                role="radio"
                disabled={wasPublishedPreviously}
                aria-checked={formState.trigger === "purchase"}
                onClick={() => updateFormState({ trigger: "purchase" })}
              >
                <img src={purchaseTriggerImage} width={40} height={40} />
                <div>
                  <h4>Purchase</h4>A customer purchases your product
                </div>
              </Button>
              <Button
                className="vertical"
                role="radio"
                disabled={wasPublishedPreviously}
                aria-checked={formState.trigger === "new_subscriber"}
                onClick={() => updateFormState({ trigger: "new_subscriber" })}
              >
                <img src={newSubscriberTriggerImage} width={40} height={40} />
                <div>
                  <h4>New subscriber</h4>A user subscribes to your email list
                </div>
              </Button>
              <Button
                className="vertical"
                role="radio"
                disabled={wasPublishedPreviously}
                aria-checked={formState.trigger === "member_cancels"}
                onClick={() => updateFormState({ trigger: "member_cancels" })}
              >
                <img src={memberCancelsTriggerImage} width={40} height={40} style={{ objectFit: "contain" }} />
                <div>
                  <h4>Member cancels</h4>A membership product subscriber cancels
                </div>
              </Button>
              <Button
                className="vertical"
                role="radio"
                disabled={wasPublishedPreviously}
                aria-checked={formState.trigger === "new_affiliate"}
                onClick={() => updateFormState({ trigger: "new_affiliate" })}
              >
                <img src={newAffiliateTriggerImage} width={40} height={40} style={{ objectFit: "contain" }} />
                <div>
                  <h4>New affiliate</h4>A user becomes an affiliate of yours
                </div>
              </Button>
              {context.eligible_for_abandoned_cart_workflows ? (
                abandonedCartButton
              ) : (
                <WithTooltip tip="You must have at least one completed payout to create abandoned cart workflows">
                  {abandonedCartButton}
                </WithTooltip>
              )}
            </div>
            {wasPublishedPreviously || formState.trigger === "abandoned_cart" ? null : (
              <label>
                <input
                  type="checkbox"
                  checked={formState.sendToPastCustomers}
                  onChange={(e) => updateFormState({ sendToPastCustomers: e.target.checked })}
                />
                {sendToPastCustomersCheckboxLabel(formState.trigger)}
              </label>
            )}
          </fieldset>
          {formState.trigger === "new_affiliate" ? (
            <fieldset>
              <legend>
                <label htmlFor="affiliated_products">Affiliated products</label>
              </legend>
              <TagInput
                inputId="affiliated_products"
                placeholder="Select products..."
                isDisabled={wasPublishedPreviously}
                tagIds={formState.affiliatedProducts}
                tagList={selectableProductAndVariantOptions(
                  context.affiliate_product_options,
                  formState.affiliatedProducts,
                )}
                onChangeTagIds={(affiliatedProducts) => updateFormState({ affiliatedProducts })}
              />
              {wasPublishedPreviously ? null : (
                <label>
                  <input
                    type="checkbox"
                    checked={
                      formState.affiliatedProducts.length ===
                      selectableProductAndVariantOptions(
                        context.affiliate_product_options,
                        formState.affiliatedProducts,
                      ).length
                    }
                    onChange={(e) =>
                      updateFormState({
                        affiliatedProducts: e.target.checked
                          ? selectableProductAndVariantOptions(
                              context.affiliate_product_options,
                              formState.affiliatedProducts,
                            ).map(({ id }) => id)
                          : [],
                      })
                    }
                  />
                  All products
                </label>
              )}
            </fieldset>
          ) : null}
          {triggerSupportsBoughtFilter ? (
            <fieldset>
              <legend>
                <label htmlFor="bought">
                  {formState.trigger === "member_cancels"
                    ? "Is a member of"
                    : formState.trigger === "abandoned_cart"
                      ? "Has products in abandoned cart"
                      : "Has bought"}
                </label>
              </legend>
              <TagInput
                inputId="bought"
                placeholder="Any product"
                isDisabled={wasPublishedPreviously}
                tagIds={formState.bought}
                tagList={selectableProductAndVariantOptions(context.products_and_variant_options, formState.bought)}
                onChangeTagIds={(bought) => updateFormState({ bought })}
              />
              {formState.trigger === "abandoned_cart" ? (
                <small>Leave this field blank to include all products</small>
              ) : null}
            </fieldset>
          ) : null}
          {triggerSupportsNotBoughtFilter ? (
            <fieldset>
              <legend>
                <label htmlFor="not_bought">
                  {formState.trigger === "abandoned_cart"
                    ? "Does not have products in abandoned cart"
                    : "Has not yet bought"}
                </label>
              </legend>
              <TagInput
                inputId="not_bought"
                placeholder="No products"
                isDisabled={wasPublishedPreviously}
                tagIds={formState.notBought}
                tagList={selectableProductAndVariantOptions(context.products_and_variant_options, formState.notBought)}
                onChangeTagIds={(notBought) => updateFormState({ notBought })}
                // Displayed as a multi-select for consistency, but supports only one option for now
                maxTags={1}
              />
            </fieldset>
          ) : null}
          {triggerSupportsPaidFilters ? (
            <div
              style={{
                display: "grid",
                gap: "var(--spacer-3)",
                gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
              }}
            >
              <fieldset className={cx({ danger: invalidFields.has("paidMoreThan") })}>
                <legend>
                  <label htmlFor="paid_more_than">Paid more than</label>
                </legend>
                <NumberInput
                  onChange={(paidMoreThan) => updateFormState({ paidMoreThan })}
                  value={formState.paidMoreThan}
                >
                  {(inputProps) => (
                    <div className={cx("input", { disabled: wasPublishedPreviously })}>
                      <div className="pill">{context.currency_symbol}</div>
                      <input
                        id="paid_more_than"
                        type="text"
                        disabled={wasPublishedPreviously}
                        ref={paidMoreThanInputRef}
                        autoComplete="off"
                        placeholder="0"
                        {...inputProps}
                      />
                    </div>
                  )}
                </NumberInput>
              </fieldset>
              <fieldset className={cx({ danger: invalidFields.has("paidLessThan") })}>
                <legend>
                  <label htmlFor="paid_less_than">Paid less than</label>
                </legend>
                <NumberInput
                  onChange={(paidLessThan) => updateFormState({ paidLessThan })}
                  value={formState.paidLessThan}
                >
                  {(inputProps) => (
                    <div className={cx("input", { disabled: wasPublishedPreviously })}>
                      <div className="pill">{context.currency_symbol}</div>
                      <input
                        id="paid_less_than"
                        type="text"
                        disabled={wasPublishedPreviously}
                        autoComplete="off"
                        placeholder="∞"
                        {...inputProps}
                      />
                    </div>
                  )}
                </NumberInput>
              </fieldset>
            </div>
          ) : null}
          {triggerSupportsDateFilters ? (
            <div
              style={{
                display: "grid",
                gap: "var(--spacer-3)",
                gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
              }}
            >
              <fieldset className={cx({ danger: invalidFields.has("afterDate") })}>
                <legend>
                  <label htmlFor="after_date">
                    {formState.trigger === "new_subscriber"
                      ? "Subscribed after"
                      : formState.trigger === "member_cancels"
                        ? "Canceled after"
                        : formState.trigger === "new_affiliate"
                          ? "Affiliate after"
                          : "Purchased after"}
                  </label>
                </legend>
                <input
                  type="date"
                  id="after_date"
                  disabled={wasPublishedPreviously}
                  ref={afterDateInputRef}
                  value={formState.afterDate}
                  onChange={(e) => updateFormState({ afterDate: e.target.value })}
                />
                <small>00:00 {context.timezone}</small>
              </fieldset>
              <fieldset className={cx({ danger: invalidFields.has("beforeDate") })}>
                <legend>
                  <label htmlFor="before_date">
                    {formState.trigger === "new_subscriber"
                      ? "Subscribed before"
                      : formState.trigger === "member_cancels"
                        ? "Canceled before"
                        : formState.trigger === "new_affiliate"
                          ? "Affiliate before"
                          : "Purchased before"}
                  </label>
                </legend>
                <input
                  type="date"
                  id="before_date"
                  disabled={wasPublishedPreviously}
                  value={formState.beforeDate}
                  onChange={(e) => updateFormState({ beforeDate: e.target.value })}
                />
                <small>11:59 {context.timezone}</small>
              </fieldset>
            </div>
          ) : null}
          {triggerSupportsFromCountryFilter ? (
            <fieldset>
              <legend>
                <label htmlFor="from_country">From</label>
              </legend>
              <select
                id="from_country"
                disabled={wasPublishedPreviously}
                value={formState.fromCountry}
                onChange={(e) => updateFormState({ fromCountry: e.target.value })}
              >
                <option value="">Anywhere</option>
                {context.countries.map((country) => (
                  <option key={country} value={country}>
                    {country}
                  </option>
                ))}
              </select>
            </fieldset>
          ) : null}
        </section>
      </form>
    </Layout>
  );
};

export default WorkflowForm;
