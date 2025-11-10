import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

export default function WorkflowsEdit() {
  const { workflow, context } = cast<{ workflow: Workflow; context: WorkflowFormContext }>(usePage().props);

  return <WorkflowForm workflow={workflow} context={context} />;
}
