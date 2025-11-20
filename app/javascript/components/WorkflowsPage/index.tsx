import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WorkflowTrigger } from "$app/components/WorkflowsPage/WorkflowForm";
export { Layout } from "$app/components/WorkflowsPage/Layout";
export { PublishButton } from "$app/components/WorkflowsPage/PublishButton";

const PAST_CUSTOMERS_LABELS: Record<WorkflowTrigger, string> = {
  new_subscriber: "Also send to past email subscribers",
  member_cancels: "Also send to past members who canceled",
  new_affiliate: "Also send to past affiliates",
  purchase: "Also send to past customers",
  abandoned_cart: "Also send to past customers",
  legacy_audience: "Also send to past customers",
};

export const sendToPastCustomersCheckboxLabel = (workflowTrigger: WorkflowTrigger) =>
  PAST_CUSTOMERS_LABELS[workflowTrigger];

export const EditPageNavigation = (props: { workflowExternalId: string }) => {
  const page = usePage();
  const currentUrl = page.url;

  return (
    <Tabs>
      <Tab isSelected={currentUrl.includes(Routes.edit_workflow_path(props.workflowExternalId))} asChild>
        <Link href={Routes.edit_workflow_path(props.workflowExternalId)}>Details</Link>
      </Tab>
      <Tab isSelected={currentUrl.includes(Routes.workflow_emails_path(props.workflowExternalId))} asChild>
        <Link href={Routes.workflow_emails_path(props.workflowExternalId)}>Emails</Link>
      </Tab>
    </Tabs>
  );
};
