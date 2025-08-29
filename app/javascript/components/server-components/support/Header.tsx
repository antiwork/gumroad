import { HelperClientProvider } from "@helperai/react";
import React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { UnreadTicketsBadge } from "$app/components/support/UnreadTicketsBadge";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

import logo from "$assets/images/logo.svg";

export function SupportHeader({
  onOpenNewTicket,
  hasHelperSession = true,
}: {
  onOpenNewTicket: () => void;
  hasHelperSession?: boolean;
}) {
  const { pathname } = new URL(useOriginalLocation());
  const isHelpArticle =
    pathname.startsWith(Routes.help_center_root_path()) && pathname !== Routes.help_center_root_path();

  return (
    <>
      <h1 className="hidden group-[.sidebar-nav]/body:block">Help</h1>
      <h1 className="group-[.sidebar-nav]/body:hidden">
        <a href={Routes.root_path()} className="flex items-center">
          <img src={logo} alt="Gumroad" className="h-8 w-auto dark:invert" />
        </a>
      </h1>
      <div className="actions">
        {isHelpArticle ? (
          <a href={Routes.help_center_root_path()} className="button" aria-label="Search" title="Search">
            <span className="icon icon-solid-search"></span>
          </a>
        ) : hasHelperSession ? (
          <Button color="accent" onClick={onOpenNewTicket}>
            New ticket
          </Button>
        ) : null}
      </div>
      {hasHelperSession ? (
        <div role="tablist">
          <a
            href={Routes.help_center_root_path()}
            role="tab"
            aria-selected={pathname.startsWith(Routes.help_center_root_path())}
            className="pb-2"
          >
            Articles
          </a>
          <a
            href={Routes.support_index_path()}
            role="tab"
            aria-selected={pathname.startsWith(Routes.support_index_path())}
            className="flex items-center gap-2 border-b-2 pb-2"
          >
            Support tickets
            <UnreadTicketsBadge />
          </a>
        </div>
      ) : null}
    </>
  );
}

type WrapperProps = {
  host?: string | null;
  session?: {
    email?: string | null;
    emailHash?: string | null;
    timestamp?: number | null;
    customerMetadata?: {
      name?: string | null;
      value?: number | null;
      links?: Record<string, string> | null;
    } | null;
    currentToken?: string | null;
  } | null;
  new_ticket_url: string;
};

const Wrapper = ({ host, session, new_ticket_url }: WrapperProps) =>
  host && session ? (
    <HelperClientProvider host={host} session={session}>
      <SupportHeader onOpenNewTicket={() => (window.location.href = new_ticket_url)} />
    </HelperClientProvider>
  ) : (
    <SupportHeader onOpenNewTicket={() => (window.location.href = new_ticket_url)} hasHelperSession={false} />
  );

export default register({ component: Wrapper, propParser: createCast() });
