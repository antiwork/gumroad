import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AudiencePage, AudiencePageProps } from "$app/components/server-components/AudiencePage";

function Audience() {
  const { audience_props } = usePage<{ audience_props: AudiencePageProps }>().props;

  return <AudiencePage {...audience_props} />;
}

export default Audience;
