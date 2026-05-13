import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

export default function WorkflowsNew() {
  const { context } = typia.assert<{ context: WorkflowFormContext }>(usePage().props);

  return <WorkflowForm context={context} />;
}
