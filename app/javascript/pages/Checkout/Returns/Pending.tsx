import * as React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export const PENDING_RELOAD_MS = 3_000;
export const PENDING_RELOAD_GIVE_UP_MS = 5 * 60 * 1_000;
export const PENDING_RELOAD_STARTED_AT_KEY = "checkout-return-pending-started-at";

function pendingReloadStorageKey() {
  return `${PENDING_RELOAD_STARTED_AT_KEY}:${window.location.pathname}`;
}

export default function Pending() {
  React.useEffect(() => {
    const storageKey = pendingReloadStorageKey();
    const stored = Number(sessionStorage.getItem(storageKey));
    const started = Number.isFinite(stored) && stored > 0 ? stored : Date.now();
    sessionStorage.setItem(storageKey, String(started));

    if (Date.now() - started >= PENDING_RELOAD_GIVE_UP_MS) return;

    const timeout = window.setTimeout(() => {
      window.location.reload();
    }, PENDING_RELOAD_MS);

    return () => window.clearTimeout(timeout);
  }, []);

  return (
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          <h2 className="grow">Your payment is being processed</h2>
        </header>
      </CardContent>
      <CardContent>
        Check your email for your receipt — it will arrive once the payment completes. Please do not pay again. This
        page updates automatically.
      </CardContent>
    </Card>
  );
}

Pending.publicLayout = true;
