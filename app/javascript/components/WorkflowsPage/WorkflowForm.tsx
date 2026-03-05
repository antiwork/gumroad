import { Link, useForm } from "@inertiajs/react";
import * as React from "react";

import {
  WorkflowFormContext,
  Workflow,
  WorkflowType,
  LegacyWorkflowTrigger,
  SaveActionName,
  ProductOption,
  VariantOption,
} from "$app/types/workflow";

import { Button } from "$app/components/Button";
import { NumberInput } from "$app/components/NumberInput";
import { TagInput } from "$app/components/TagInput";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Select } from "$app/components/ui/Select";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";
import {
  Layout,
  EditPageNavigation,
  sendToPastCustomersCheckboxLabel,
  PublishButton,
} from "$app/components/WorkflowsPage";

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

type WorkflowFormProps = {
  context: WorkflowFormContext;
  workflow?: Workflow;
};

const WorkflowForm = ({ context, workflow }: WorkflowFormProps) => {
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
  const form = useForm({});
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

  const handleSave = (saveActionName: SaveActionName = "save") => {
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

    form.transform(() => ({
      workflow: {
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
      },
    }));

    if (workflow) {
      form.patch(Routes.workflow_path(workflow.external_id), {
        only: ["workflow", "flash"],
      });
    } else {
      form.post(Routes.workflows_path());
    }
  };

  const abandonedCartButton = (
    <Tab isSelected={formState.trigger === "abandoned_cart"} asChild>
      <Button
        className="flex-col"
        role="radio"
        disabled={wasPublishedPreviously || !context.eligible_for_abandoned_cart_workflows}
        aria-checked={formState.trigger === "abandoned_cart"}
        onClick={() => updateFormState({ trigger: "abandoned_cart" })}
      >
        <img src={abandonedCartTriggerImage} width={40} height={40} className="shrink-0" />
        <div>
          <h4 className="font-bold">Abandoned cart</h4>A customer doesn't complete checking out
        </div>
      </Button>
    </Tab>
  );

  return (
    <Layout
      title={workflow ? workflow.name : "New workflow"}
      navigation={workflow ? <EditPageNavigation workflowExternalId={workflow.external_id} /> : null}
      actions={
        <>
          <Button asChild>
            <Link href={Routes.workflows_path()} inert={form.processing || undefined}>
              Cancel
            </Link>
          </Button>
          <Button color="primary" onClick={() => handleSave()} disabled={form.processing}>
            {workflow ? "Save changes" : "Save and continue"}
          </Button>
          {workflow ? (
            <PublishButton
              isPublished={workflow.published}
              wasPublishedPreviously={wasPublishedPreviously}
              isDisabled={form.processing}
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
      <form className="space-y-4">
        <FormSection
          header={<>Workflows allow you to send scheduled emails to a subset of your audience based on a trigger.</>}
        >
          <Fieldset state={invalidFields.has("name") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor="name">Name</Label>
            </FieldsetTitle>
            <Input
              id="name"
              type="text"
              ref={nameInputRef}
              placeholder="Name of workflow"
              maxLength={255}
              value={formState.name}
              onChange={(e) => updateFormState({ name: e.target.value })}
            />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor="trigger">Trigger</Label>
            </FieldsetTitle>
            <Tabs
              variant="buttons"
              className="gap-4 sm:grid-cols-2 md:grid-flow-row md:grid-cols-3 2xl:grid-cols-5"
              role="radiogroup"
            >
              {workflow && workflow.workflow_type === "audience" ? (
                <Tab isSelected={formState.trigger === "legacy_audience"} asChild>
                  <Button
                    className="flex-col"
                    role="radio"
                    aria-checked={formState.trigger === "legacy_audience"}
                    disabled={wasPublishedPreviously}
                    onClick={() => updateFormState({ trigger: "legacy_audience" })}
                  >
                    <img src={audienceTriggerImage} width={40} height={40} className="shrink-0" />
                    <div>
                      <h4 className="font-bold">Audience</h4>A user becomes a customer, subscriber or an affiliate
                    </div>
                  </Button>
                </Tab>
              ) : null}
              <Tab isSelected={formState.trigger === "purchase"} asChild>
                <Button
                  className="flex-col"
                  role="radio"
                  aria-checked={formState.trigger === "purchase"}
                  disabled={wasPublishedPreviously}
                  onClick={() => updateFormState({ trigger: "purchase" })}
                >
                  <img src={purchaseTriggerImage} width={40} height={40} className="shrink-0" />
                  <div>
                    <h4 className="font-bold">Purchase</h4>A customer purchases your product
                  </div>
                </Button>
              </Tab>
              <Tab isSelected={formState.trigger === "new_subscriber"} asChild>
                <Button
                  className="flex-col"
                  role="radio"
                  aria-checked={formState.trigger === "new_subscriber"}
                  disabled={wasPublishedPreviously}
                  onClick={() => updateFormState({ trigger: "new_subscriber" })}
                >
                  <img src={newSubscriberTriggerImage} width={40} height={40} className="shrink-0" />
                  <div>
                    <h4 className="font-bold">New subscriber</h4>A user subscribes to your email list
                  </div>
                </Button>
              </Tab>
              <Tab isSelected={formState.trigger === "member_cancels"} asChild>
                <Button
                  className="flex-col"
                  role="radio"
                  aria-checked={formState.trigger === "member_cancels"}
                  disabled={wasPublishedPreviously}
                  onClick={() => updateFormState({ trigger: "member_cancels" })}
                >
                  <img
                    src={memberCancelsTriggerImage}
                    width={40}
                    height={40}
                    className="shrink-0"
                    style={{ objectFit: "contain" }}
                  />
                  <div>
                    <h4 className="font-bold">Member cancels</h4>A membership product subscriber cancels
                  </div>
                </Button>
              </Tab>
              <Tab isSelected={formState.trigger === "new_affiliate"} asChild>
                <Button
                  className="flex-col"
                  role="radio"
                  aria-checked={formState.trigger === "new_affiliate"}
                  disabled={wasPublishedPreviously}
                  onClick={() => updateFormState({ trigger: "new_affiliate" })}
                >
                  <img
                    src={newAffiliateTriggerImage}
                    width={40}
                    height={40}
                    className="shrink-0"
                    style={{ objectFit: "contain" }}
                  />
                  <div>
                    <h4 className="font-bold">New affiliate</h4>A user becomes an affiliate of yours
                  </div>
                </Button>
              </Tab>
              {context.eligible_for_abandoned_cart_workflows ? (
                abandonedCartButton
              ) : (
                <WithTooltip tip="You must have at least one completed payout to create abandoned cart workflows">
                  {abandonedCartButton}
                </WithTooltip>
              )}
            </Tabs>
            {wasPublishedPreviously || formState.trigger === "abandoned_cart" ? null : (
              <Label>
                <Checkbox
                  checked={formState.sendToPastCustomers}
                  onChange={(e) => updateFormState({ sendToPastCustomers: e.target.checked })}
                />
                {sendToPastCustomersCheckboxLabel(formState.trigger)}
              </Label>
            )}
          </Fieldset>
          {formState.trigger === "new_affiliate" ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="affiliated_products">Affiliated products</Label>
              </FieldsetTitle>
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
                <Label>
                  <Checkbox
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
                </Label>
              )}
            </Fieldset>
          ) : null}
          {triggerSupportsBoughtFilter ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="bought">
                  {formState.trigger === "member_cancels"
                    ? "Is a member of"
                    : formState.trigger === "abandoned_cart"
                      ? "Has products in abandoned cart"
                      : "Has bought"}
                </Label>
              </FieldsetTitle>
              <TagInput
                inputId="bought"
                placeholder="Any product"
                isDisabled={wasPublishedPreviously}
                tagIds={formState.bought}
                tagList={selectableProductAndVariantOptions(context.products_and_variant_options, formState.bought)}
                onChangeTagIds={(bought) => updateFormState({ bought })}
              />
              {formState.trigger === "abandoned_cart" ? (
                <FieldsetDescription>Leave this field blank to include all products</FieldsetDescription>
              ) : null}
            </Fieldset>
          ) : null}
          {triggerSupportsNotBoughtFilter ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="not_bought">
                  {formState.trigger === "abandoned_cart"
                    ? "Does not have products in abandoned cart"
                    : "Has not yet bought"}
                </Label>
              </FieldsetTitle>
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
            </Fieldset>
          ) : null}
          {triggerSupportsPaidFilters ? (
            <div
              style={{
                display: "grid",
                gap: "var(--spacer-3)",
                gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
              }}
            >
              <Fieldset state={invalidFields.has("paidMoreThan") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor="paid_more_than">Paid more than</Label>
                </FieldsetTitle>
                <NumberInput
                  onChange={(paidMoreThan) => updateFormState({ paidMoreThan })}
                  value={formState.paidMoreThan}
                >
                  {(inputProps) => (
                    <InputGroup disabled={wasPublishedPreviously}>
                      <Pill className="-ml-2 shrink-0">{context.currency_symbol}</Pill>
                      <Input
                        id="paid_more_than"
                        type="text"
                        disabled={wasPublishedPreviously}
                        ref={paidMoreThanInputRef}
                        autoComplete="off"
                        placeholder="0"
                        {...inputProps}
                      />
                    </InputGroup>
                  )}
                </NumberInput>
              </Fieldset>
              <Fieldset state={invalidFields.has("paidLessThan") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor="paid_less_than">Paid less than</Label>
                </FieldsetTitle>
                <NumberInput
                  onChange={(paidLessThan) => updateFormState({ paidLessThan })}
                  value={formState.paidLessThan}
                >
                  {(inputProps) => (
                    <InputGroup disabled={wasPublishedPreviously}>
                      <Pill className="-ml-2 shrink-0">{context.currency_symbol}</Pill>
                      <Input
                        id="paid_less_than"
                        type="text"
                        disabled={wasPublishedPreviously}
                        autoComplete="off"
                        placeholder="∞"
                        {...inputProps}
                      />
                    </InputGroup>
                  )}
                </NumberInput>
              </Fieldset>
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
              <Fieldset state={invalidFields.has("afterDate") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor="after_date">
                    {formState.trigger === "new_subscriber"
                      ? "Subscribed after"
                      : formState.trigger === "member_cancels"
                        ? "Canceled after"
                        : formState.trigger === "new_affiliate"
                          ? "Affiliate after"
                          : "Purchased after"}
                  </Label>
                </FieldsetTitle>
                <Input
                  type="date"
                  id="after_date"
                  disabled={wasPublishedPreviously}
                  ref={afterDateInputRef}
                  value={formState.afterDate}
                  onChange={(e) => updateFormState({ afterDate: e.target.value })}
                />
                <FieldsetDescription>00:00 {context.timezone}</FieldsetDescription>
              </Fieldset>
              <Fieldset state={invalidFields.has("beforeDate") ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor="before_date">
                    {formState.trigger === "new_subscriber"
                      ? "Subscribed before"
                      : formState.trigger === "member_cancels"
                        ? "Canceled before"
                        : formState.trigger === "new_affiliate"
                          ? "Affiliate before"
                          : "Purchased before"}
                  </Label>
                </FieldsetTitle>
                <Input
                  type="date"
                  id="before_date"
                  disabled={wasPublishedPreviously}
                  value={formState.beforeDate}
                  onChange={(e) => updateFormState({ beforeDate: e.target.value })}
                />
                <FieldsetDescription>11:59 {context.timezone}</FieldsetDescription>
              </Fieldset>
            </div>
          ) : null}
          {triggerSupportsFromCountryFilter ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="from_country">From</Label>
              </FieldsetTitle>
              <Select
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
              </Select>
            </Fieldset>
          ) : null}
        </FormSection>
      </form>
    </Layout>
  );
};

export default WorkflowForm;
