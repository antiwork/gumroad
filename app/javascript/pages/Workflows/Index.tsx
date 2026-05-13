import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { Workflow } from "$app/types/workflow";

import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

export default function WorkflowsIndex() {
  const { workflows } = typia.assert<{ workflows: Workflow[] }>(usePage().props);

  return <WorkflowList workflows={workflows} />;
}
