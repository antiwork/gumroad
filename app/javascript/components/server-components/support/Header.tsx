import { HelperClientProvider } from "@helperai/react";
import React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { UnauthenticatedNewTicketModal } from "$app/components/support/UnauthenticatedNewTicketModal";
import { UnreadTicketsBadge } from "$app/components/support/UnreadTicketsBadge";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

export function SupportHeader({
  onOpenNewTicket,
  hasHelperSession = true,
  recaptchaSiteKey,
}: {
  onOpenNewTicket: () => void;
  hasHelperSession?: boolean;
  recaptchaSiteKey?: string | null;
}) {
  const { pathname, searchParams } = new URL(useOriginalLocation());
  const isHelpArticle =
    pathname.startsWith(Routes.help_center_root_path()) && pathname !== Routes.help_center_root_path();
  const isAnonymousUserOnHelpCenter = !hasHelperSession && pathname === Routes.help_center_root_path();

  const [isUnauthenticatedNewTicketOpen, setIsUnauthenticatedNewTicketOpen] = React.useState(
    isAnonymousUserOnHelpCenter && !!searchParams.get("new_ticket"),
  );

  React.useEffect(() => {
    if (isAnonymousUserOnHelpCenter) {
      const url = new URL(location.href);
      if (!isUnauthenticatedNewTicketOpen && url.searchParams.get("new_ticket")) {
        url.searchParams.delete("new_ticket");
        history.replaceState(null, "", url.toString());
      }
    }
  }, [isUnauthenticatedNewTicketOpen, isAnonymousUserOnHelpCenter]);

  return (
    <>
      <PageHeader
        title="Help Center"
        actions={
          isHelpArticle ? (
            <a href={Routes.help_center_root_path()} className="button" aria-label="Search" title="Search">
              <Icon name="solid-search" />
            </a>
          ) : isAnonymousUserOnHelpCenter ? (
            <>
              <NavigationButton
                color="accent"
                outline
                href="https://github.com/antiwork/gumroad/issues/new"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-2"
              >
                <svg width="16" height="16" viewBox="0 0 98 96" xmlns="http://www.w3.org/2000/svg" className="fill-current">
                  <path
                    fillRule="evenodd"
                    clipRule="evenodd"
                    d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
                    fill="currentColor"
                  />
                </svg>
                Report a bug
              </NavigationButton>
              <Button color="accent" onClick={() => setIsUnauthenticatedNewTicketOpen(true)}>
                Contact support
              </Button>
            </>
          ) : hasHelperSession ? (
            <>
              <NavigationButton
                color="accent"
                outline
                href="https://github.com/antiwork/gumroad/issues/new"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-2"
              >
                <svg width="16" height="16" viewBox="0 0 98 96" xmlns="http://www.w3.org/2000/svg" className="fill-current">
                  <path
                    fillRule="evenodd"
                    clipRule="evenodd"
                    d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
                    fill="currentColor"
                  />
                </svg>
                Report a bug
              </NavigationButton>
              <Button color="accent" onClick={onOpenNewTicket}>
                New ticket
              </Button>
            </>
          ) : null
        }
      >
        {hasHelperSession ? (
          <Tabs>
            <Tab href={Routes.help_center_root_path()} isSelected={pathname.startsWith(Routes.help_center_root_path())}>
              Articles
            </Tab>
            <Tab
              href={Routes.support_index_path()}
              isSelected={pathname.startsWith(Routes.support_index_path())}
              className="flex items-center gap-2"
            >
              Support tickets
              <UnreadTicketsBadge />
            </Tab>
          </Tabs>
        ) : null}
      </PageHeader>
      {isAnonymousUserOnHelpCenter ? (
        <UnauthenticatedNewTicketModal
          open={isUnauthenticatedNewTicketOpen}
          onClose={() => setIsUnauthenticatedNewTicketOpen(false)}
          onCreated={() => setIsUnauthenticatedNewTicketOpen(false)}
          recaptchaSiteKey={recaptchaSiteKey ?? null}
        />
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
  recaptcha_site_key?: string | null;
};

const Wrapper = ({ host, session, new_ticket_url, recaptcha_site_key }: WrapperProps) =>
  host && session ? (
    <HelperClientProvider host={host} session={session}>
      <SupportHeader onOpenNewTicket={() => (window.location.href = new_ticket_url)} />
    </HelperClientProvider>
  ) : (
    <SupportHeader
      onOpenNewTicket={() => (window.location.href = new_ticket_url)}
      hasHelperSession={false}
      recaptchaSiteKey={recaptcha_site_key ?? null}
    />
  );

export default register({ component: Wrapper, propParser: createCast() });
