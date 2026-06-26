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
    <div className="flex h-screen flex-col">
      <PageHeader title="Agent" />
      <div className="min-h-0 flex-1">
        <AgentChat greeting={greeting} suggestions={suggestions} />
      </div>
    </div>
  );
};

export default AgentPage;
