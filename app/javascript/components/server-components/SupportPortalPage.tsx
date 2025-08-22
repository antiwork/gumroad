import { HelperClientProvider } from "@helperai/react";
import React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import SupportPortal from "$app/components/support/SupportPortal";

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
};

function SupportPortalPage({ host, session }: Props) {
  return (
    <HelperClientProvider host={host} session={session}>
      <SupportPortal />
    </HelperClientProvider>
  );
}

export default register({ component: SupportPortalPage, propParser: createCast() });
