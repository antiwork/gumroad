import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { formatPostDate } from "$app/utils/date";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Card, CardContent } from "$app/components/ui/Card";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { useUserAgentInfo } from "$app/components/UserAgent";

export type AgentClient = {
  key: string;
  label: string;
  capability: string;
  connected: boolean;
  first_connected_at: string | null;
  last_used_at: string | null;
  pending_review: boolean;
  directory_url: string | null;
  connect_label: string | null;
  availability: string;
  setup: string;
  endpoint_url: string;
};

export type AgentPageProps = {
  title: string;
  description: string;
  clients: AgentClient[];
  example_prompts: { prompt: string; description: string }[];
  help_article_url: string;
};

const ClientCard = ({ client }: { client: AgentClient }) => {
  const { locale } = useUserAgentInfo();
  const headingId = `agent-client-${client.key}`;
  const endpointId = `agent-endpoint-${client.key}`;

  return (
    <Card asChild>
      <section aria-labelledby={headingId} className="grid lg:row-span-2 lg:grid-rows-subgrid">
        <CardContent details className="grid gap-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 id={headingId} className="text-lg font-bold">
              {client.label}
            </h2>
            {client.connected ? (
              <Pill color="success" size="small">
                {client.first_connected_at
                  ? `Connected ${formatPostDate(client.first_connected_at, locale)}`
                  : "Connected"}
              </Pill>
            ) : (
              <Pill size="small">Not connected</Pill>
            )}
          </div>
          <p>{client.capability}</p>
          {client.pending_review ? (
            <div className="grid gap-2">
              <Button disabled aria-describedby={`${headingId}-availability`}>
                {`Add Gumroad to ${client.label}`}
              </Button>
              <p id={`${headingId}-availability`} className="text-muted">
                {client.availability}
              </p>
            </div>
          ) : client.directory_url ? (
            <div className="grid gap-2">
              <NavigationButton color="accent" href={client.directory_url} target="_blank" rel="noopener noreferrer">
                {client.connect_label ?? `Add Gumroad to ${client.label}`}
              </NavigationButton>
              <p className="text-muted">{client.availability}</p>
            </div>
          ) : null}
        </CardContent>
        <CardContent details className="grid content-start gap-2">
          <h3 className="font-bold">Setup</h3>
          <p>{client.setup}</p>
          <div className="flex flex-wrap items-start gap-2">
            <div id={endpointId} className="min-w-0 grow">
              <CodeSnippet>{client.endpoint_url}</CodeSnippet>
            </div>
            <div className="shrink-0">
              <CopyToClipboard text={client.endpoint_url}>
                <Button size="sm" aria-label={`Copy ${client.label} connector URL`} aria-describedby={endpointId}>
                  Copy
                </Button>
              </CopyToClipboard>
            </div>
          </div>
        </CardContent>
      </section>
    </Card>
  );
};

const AgentPage = () => {
  const { title, description, clients, example_prompts, help_article_url } = cast<AgentPageProps>(usePage().props);

  return (
    <>
      <PageHeader title="Agent" showTitleOnMobile />
      <div className="grid gap-8 p-4 md:p-8">
        <section className="grid gap-2" aria-labelledby="agent-intro-title">
          <h2 id="agent-intro-title" className="text-2xl">
            {title}
          </h2>
          <p className="max-w-3xl">{description}</p>
        </section>

        {/* Row subgrid: the Setup divider sits at the same height on all three cards. */}
        <section aria-label="AI clients" className="grid gap-4 lg:grid-cols-3 lg:grid-rows-[auto_auto]">
          {clients.map((client) => (
            <ClientCard key={client.key} client={client} />
          ))}
        </section>

        <section className="grid gap-4" aria-labelledby="agent-examples-title">
          <h2 id="agent-examples-title" className="text-xl">
            What you can do
          </h2>
          <Card asChild>
            <ul>
              {example_prompts.map((example) => (
                <CardContent asChild details key={example.prompt}>
                  <li>
                    <p className="font-bold">“{example.prompt}”</p>
                    <p className="text-muted">{example.description}</p>
                  </li>
                </CardContent>
              ))}
            </ul>
          </Card>
        </section>

        <footer>
          <a href={help_article_url} target="_blank" rel="noopener noreferrer" className="underline">
            Read the setup guide: connecting AI assistants to your Gumroad store
          </a>
        </footer>
      </div>
    </>
  );
};

export default AgentPage;
