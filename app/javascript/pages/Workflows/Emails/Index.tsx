import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";

import WorkflowEmails from "$app/components/WorkflowsPage/WorkflowEmails";

export default function WorkflowsEmailsIndex() {
  const { workflow, context } = typia.assert<{ workflow: Workflow; context: WorkflowFormContext }>(usePage().props);

  return <WorkflowEmails workflow={workflow} context={context} />;
}
