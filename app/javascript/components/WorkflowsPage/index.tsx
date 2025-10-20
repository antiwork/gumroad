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
      <Tab isSelected={currentUrl.includes(`/workflows/${props.workflowExternalId}/edit`)} asChild>
        <Link href={`/workflows/${props.workflowExternalId}/edit`}>Details</Link>
      </Tab>
      <Tab isSelected={currentUrl.includes(`/workflows/${props.workflowExternalId}/emails`)} asChild>
        <Link href={`/workflows/${props.workflowExternalId}/emails`}>Emails</Link>
      </Tab>
    </Tabs>
  );
};
