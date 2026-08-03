import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { AgentChat } from "$app/components/Agent/AgentChat";
import { PageHeader } from "$app/components/ui/PageHeader";

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
    <div className="flex h-full flex-col">
      {/* On phones the header has no actions and its title is already hidden (<sm), so it would render
          as an empty bar under the mobile nav. Hide it entirely there; show it from sm up. */}
      <PageHeader title="Agent" className="hidden sm:flex" />
      <div className="min-h-0 flex-1">
        <AgentChat
          greeting={greeting}
          suggestions={suggestions}
          locked={eligible ? null : { heading: locked_heading, explanation: locked_explanation }}
        />
      </div>
    </div>
  );
};

export default AgentPage;
