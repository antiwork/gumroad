import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";

import WorkflowEmails from "$app/components/WorkflowsPage/WorkflowEmails";

function WorkflowEmailsPage() {
  const { workflow, context } = usePage<{ workflow: Workflow; context: WorkflowFormContext }>().props;

  return <WorkflowEmails workflow={workflow} context={context} />;
}

export default WorkflowEmailsPage;
