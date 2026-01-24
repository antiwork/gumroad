import * as React from "react";

import { CommunitiesPage } from "../../components/server-components/CommunitiesPage";

// This Inertia page is a thin wrapper around the production CommunitiesPage component.


const CommunitiesIndex = (props: any) => {
  return <CommunitiesPage {...props} />;
};

export default CommunitiesIndex;
