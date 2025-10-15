import { usePage } from "@inertiajs/react";
import React from "react";

import { WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

function WorkflowNew() {
  const { context } = usePage<{ context: WorkflowFormContext }>().props;

  return <WorkflowForm context={context} />;
}

export default WorkflowNew;
