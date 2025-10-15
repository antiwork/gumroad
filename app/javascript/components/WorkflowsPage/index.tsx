import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { SaveActionName } from "$app/types/workflow";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Toggle } from "$app/components/Toggle";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WorkflowTrigger } from "$app/components/WorkflowsPage/WorkflowForm";
export { Layout } from "$app/components/WorkflowsPage/Layout";

type PublishButtonProps = {
  isPublished: boolean;
  wasPublishedPreviously: boolean;
  isDisabled: boolean;
  sendToPastCustomers: {
    enabled: boolean;
    toggle: (value: boolean) => void;
    label: string;
  } | null;
  onClick: (saveActionName: SaveActionName) => void;
};

export const PublishButton = ({
  isPublished,
  wasPublishedPreviously,
  isDisabled,
  sendToPastCustomers,
  onClick,
}: PublishButtonProps) => {
  const [popoverOpen, setPopoverOpen] = React.useState(false);

  return isPublished ? (
    <Button onClick={() => onClick("save_and_unpublish")} disabled={isDisabled}>
      Unpublish
    </Button>
  ) : wasPublishedPreviously || sendToPastCustomers === null ? (
    <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
      Publish
    </Button>
  ) : (
    <Popover
      disabled={isDisabled}
      trigger={
        <div className="button" color="accent">
          Publish
          <Icon name="outline-cheveron-down" />
        </div>
      }
      open={popoverOpen}
      onToggle={setPopoverOpen}
    >
      <fieldset>
        <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
          Publish now
        </Button>
        <Toggle value={sendToPastCustomers.enabled} onChange={sendToPastCustomers.toggle}>
          {sendToPastCustomers.label}
        </Toggle>
      </fieldset>
    </Popover>
  );
};

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
