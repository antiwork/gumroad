import { usePage } from "@inertiajs/react";
import React from "react";

import { Workflow } from "$app/data/workflows";

import WorkflowList from "$app/components/WorkflowsPage/WorkflowList";

function index() {
  const { workflows } = usePage<{ workflows: Workflow[] }>().props;

  return <WorkflowList workflows={workflows} />;
}

export default index;
