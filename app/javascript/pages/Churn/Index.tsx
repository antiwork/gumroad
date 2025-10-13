import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ChurnPage, ChurnProps } from "$app/components/Churn";

function Churn() {
  const { churn_props } = usePage<{ churn_props: ChurnProps }>().props;

  return <ChurnPage {...churn_props} />;
}

export default Churn;
