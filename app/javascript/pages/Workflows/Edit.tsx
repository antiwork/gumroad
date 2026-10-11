import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";
import { cast } from "$app/utils/cast";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

export default function WorkflowsEdit() {
  const { workflow, context } = cast<{ workflow: Workflow; context: WorkflowFormContext }>(usePage().props);

  return <WorkflowForm workflow={workflow} context={context} />;
}
