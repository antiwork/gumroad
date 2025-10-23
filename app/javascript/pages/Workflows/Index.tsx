import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow } from "$app/types/workflow";

import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

function WorkflowsIndex() {
  const { workflows } = usePage<{ workflows: Workflow[] }>().props;

  return <WorkflowList workflows={workflows} />;
}

export default WorkflowsIndex;
