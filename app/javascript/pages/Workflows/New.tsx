import { usePage } from "@inertiajs/react";
import React from "react";

import { WorkflowFormContext } from "$app/types/workflow";
import { cast } from "$app/utils/cast";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

export default function WorkflowsNew() {
  const { context } = cast<{ context: WorkflowFormContext }>(usePage().props);

  return <WorkflowForm context={context} />;
}
