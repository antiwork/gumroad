import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Workflow } from "$app/types/workflow";

import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

export default function WorkflowsIndex() {
  const { workflows } = cast<{ workflows: Workflow[] }>(usePage().props);

  return <WorkflowList workflows={workflows} />;
}
