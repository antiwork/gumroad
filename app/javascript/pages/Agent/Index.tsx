import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { AgentChat } from "$app/components/Agent/AgentChat";
import { PageHeader } from "$app/components/ui/PageHeader";

type AgentPageProps = {
  greeting: string;
  suggestions: string[];
};

const AgentPage = () => {
  const { greeting, suggestions } = typia.assert<AgentPageProps>(usePage().props);

  return (
    <div className="flex h-full flex-col">
      {/* On phones the header has no actions and its title is already hidden (<sm), so it would render
          as an empty bar under the mobile nav. Hide it entirely there; show it from sm up. */}
      <PageHeader title="Agent" className="hidden sm:flex" />
      <div className="min-h-0 flex-1">
        <AgentChat greeting={greeting} suggestions={suggestions} />
      </div>
    </div>
  );
};

export default AgentPage;
