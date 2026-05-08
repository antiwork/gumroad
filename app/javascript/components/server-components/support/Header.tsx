import { Search } from "@boxicons/react";
import { HelperClientProvider } from "@helperai/react";
import React from "react";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

const SUPPORT_EMAIL = "mailto:support@gumroad.com";

export function SupportHeader({ hasHelperSession = true }: { hasHelperSession?: boolean }) {
  const { pathname } = new URL(useOriginalLocation());
  const isHelpArticle = pathname.startsWith(Routes.help_center_root_path()) && pathname !== Routes.help_center_root_path();

  return (
    <PageHeader
      title="Help Center"
      actions={
        isHelpArticle ? (
          <Button asChild>
            <a href={Routes.help_center_root_path()} aria-label="Search" title="Search">
              <Search className="size-5" />
            </a>
          </Button>
        ) : (
          <Button color="accent" asChild>
            <a href={SUPPORT_EMAIL}>Email support</a>
          </Button>
        )
      }
    />
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

const Wrapper = ({ host, session }: WrapperProps) =>
  host && session ? (
    <HelperClientProvider host={host} session={session}>
      <SupportHeader />
    </HelperClientProvider>
  ) : (
    <SupportHeader hasHelperSession={false} />
  );

export default Wrapper;
