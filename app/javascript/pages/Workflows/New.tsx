import { usePage } from "@inertiajs/react";
import React from "react";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";
import { WorkflowFormContext } from "$app/data/workflows";

function WorkflowNew() {
  const { context } = usePage<{ context: WorkflowFormContext }>().props;

  return <WorkflowForm context={context} />;
}

export default WorkflowNew;
