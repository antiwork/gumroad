import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ChurnPage, ChurnProps, ChurnData } from "$app/components/Churn";

function Churn() {
  const { churn_props, churn_data } = usePage<{
    churn_props: ChurnProps;
    churn_data: ChurnData | null;
  }>().props;

  return <ChurnPage {...churn_props} initialData={churn_data} />;
}

export default Churn;
