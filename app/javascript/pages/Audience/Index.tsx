import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AudiencePage } from "$app/components/AudiencePage";

function Audience() {
  const { total_follower_count } = usePage<{ total_follower_count: number }>().props;

  return <AudiencePage total_follower_count={total_follower_count} />;
}

export default Audience;
