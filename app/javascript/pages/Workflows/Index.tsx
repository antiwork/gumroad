import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow } from "$app/types/workflow";
import { cast } from "$app/utils/cast";

import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

export default function WorkflowsIndex() {
  const { workflows } = cast<{ workflows: Workflow[] }>(usePage().props);

  return <WorkflowList workflows={workflows} />;
}
