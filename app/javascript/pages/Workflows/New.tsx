import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

export default function WorkflowsNew() {
  const { context } = cast<{ context: WorkflowFormContext }>(usePage().props);

  return <WorkflowForm context={context} />;
}
