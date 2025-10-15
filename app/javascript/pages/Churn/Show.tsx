import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ChurnPage, ChurnProps } from "$app/components/Churn";

function Churn() {
  const props = usePage<ChurnProps>().props;

  return <ChurnPage {...props} />;
}

export default Churn;
