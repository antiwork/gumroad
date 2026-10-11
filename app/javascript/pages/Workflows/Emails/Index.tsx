import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";
import { cast } from "$app/utils/cast";

import WorkflowEmails from "$app/components/WorkflowsPage/WorkflowEmails";

export default function WorkflowsEmailsIndex() {
  const { workflow, context } = cast<{ workflow: Workflow; context: WorkflowFormContext }>(usePage().props);

  return <WorkflowEmails workflow={workflow} context={context} />;
}
