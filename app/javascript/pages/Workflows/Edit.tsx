import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

function WorkflowEdit() {
  const { workflow, context } = usePage<{ workflow: Workflow; context: WorkflowFormContext }>().props;

  return <WorkflowForm workflow={workflow} context={context} />;
}

export default WorkflowEdit;
