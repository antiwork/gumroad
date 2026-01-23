import { usePage } from "@inertiajs/react";
import * as React from "react";

import { DiscoverPage, type DiscoverPageProps } from "$app/components/DiscoverPage";

function DiscoverIndex() {
  const props = usePage<DiscoverPageProps>().props;

  return <DiscoverPage {...props} />;
}

DiscoverIndex.loggedInUserLayout = true;

export default DiscoverIndex;
