import { HelperClientProvider } from "@helperai/react";
import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import SupportPortal from "$app/components/support/SupportPortal";

type SupportSession = {
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

type Props = {
  host: string;
  session: SupportSession;
};

export default function SupportIndex() {
  const { host, session } = cast<Props>(usePage().props);

  return (
    <HelperClientProvider host={host} session={session}>
      <SupportPortal />
    </HelperClientProvider>
  );
}
