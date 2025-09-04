import { HelperClientProvider } from "@helperai/react";
import React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import SupportPortal from "$app/components/support/SupportPortal";
import UnauthenticatedSupportPortal from "$app/components/support/UnauthenticatedSupportPortal";

type Props = {
  host: string;
  session: {
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
  recaptcha_site_key?: string | null;
};

function SupportPortalPage({ host, session, recaptcha_site_key }: Props) {
  return (
    <HelperClientProvider host={host} session={session}>
      {session?.email ? (
        <SupportPortal />
      ) : (
        <UnauthenticatedSupportPortal recaptchaSiteKey={recaptcha_site_key ?? null} />
      )}
    </HelperClientProvider>
  );
}

export default register({ component: SupportPortalPage, propParser: createCast() });
