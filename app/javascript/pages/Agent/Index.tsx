import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { AgentChat } from "$app/components/Agent/AgentChat";

type AgentPageProps = {
  greeting: string;
  suggestions: string[];
  eligible: boolean;
  locked_heading: string;
  locked_explanation: string;
};

const AgentPage = () => {
  const { greeting, suggestions, eligible, locked_heading, locked_explanation } = typia.assert<AgentPageProps>(
    usePage().props,
  );

  return (
    <AgentChat
      greeting={greeting}
      suggestions={suggestions}
      locked={eligible ? null : { heading: locked_heading, explanation: locked_explanation }}
    />
  );
};

export default AgentPage;
