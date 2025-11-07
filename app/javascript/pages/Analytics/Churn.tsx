import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ChurnPage, ChurnProps as ChurnPageProps } from "$app/components/Analytics/Churn";

function Churn() {
  const { churn_props } = usePage<{ churn_props: ChurnPageProps }>().props;

  return <ChurnPage {...churn_props} />;
}

export default Churn;
