import { HelperClientProvider } from "@helperai/react";
import React from "react";

import { SupportHeader } from "$app/components/server-components/support/Header";

type HelperSession = {
  email?: string | null;
  emailHash?: string | null;
  timestamp?: number | null;
  customerMetadata?: {
    name?: string | null;
    value?: number | null;
    links?: Record<string, string> | null;
  } | null;
  currentToken?: string | null;
};

type HelpCenterLayoutProps = {
  host: string | null;
  session: HelperSession | null;
  recaptchaSiteKey: string | null;
  children: React.ReactNode;
};

export function HelpCenterLayout({ host, session, recaptchaSiteKey, children }: HelpCenterLayoutProps) {
  const [isNewTicketOpen, setIsNewTicketOpen] = React.useState(false);

  const handleOpenNewTicket = () => {
    if (host && session) {
      setIsNewTicketOpen(true);
    }
  };

  React.useEffect(() => {
    if (isNewTicketOpen && host && session) {
      window.location.href = Routes.support_index_path({ new_ticket: true });
    }
  }, [isNewTicketOpen, host, session]);

  return host && session ? (
    <HelperClientProvider host={host} session={session}>
      <main>
        <SupportHeader onOpenNewTicket={handleOpenNewTicket} />
        <section className="p-4 md:p-8">{children}</section>
      </main>
    </HelperClientProvider>
  ) : (
    <main>
      <SupportHeader
        onOpenNewTicket={handleOpenNewTicket}
        hasHelperSession={false}
        recaptchaSiteKey={recaptchaSiteKey}
      />
      <section className="p-4 md:p-8">{children}</section>
    </main>
  );
}
