import * as React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export const PENDING_RELOAD_MS = 3_000;
export const PENDING_RELOAD_GIVE_UP_MS = 5 * 60 * 1_000;
export const PENDING_RELOAD_STARTED_AT_KEY = "checkout-return-pending-started-at";
export const PENDING_STARTED_AT_PARAM = "pending_started_at";

function pendingReloadStorageKey() {
  return `${PENDING_RELOAD_STARTED_AT_KEY}:${window.location.pathname}`;
}

function readStartedAt(storageKey: string): number {
  try {
    const stored = Number(sessionStorage.getItem(storageKey));
    if (Number.isFinite(stored) && stored > 0) return stored;
  } catch {
    // sessionStorage throws in some privacy modes; fall through.
  }

  const fromUrl = Number(new URLSearchParams(window.location.search).get(PENDING_STARTED_AT_PARAM));
  if (Number.isFinite(fromUrl) && fromUrl > 0) return fromUrl;

  return Date.now();
}

function persistStartedAt(storageKey: string, started: number): boolean {
  try {
    sessionStorage.setItem(storageKey, String(started));
    return true;
  } catch {
    return false;
  }
}

export default function Pending() {
  React.useEffect(() => {
    const storageKey = pendingReloadStorageKey();
    const started = readStartedAt(storageKey);
    if (Date.now() - started >= PENDING_RELOAD_GIVE_UP_MS) return;

    const stored = persistStartedAt(storageKey, started);

    const timeout = window.setTimeout(() => {
      if (!stored) {
        const url = new URL(window.location.href);
        if (url.searchParams.get(PENDING_STARTED_AT_PARAM) !== String(started)) {
          url.searchParams.set(PENDING_STARTED_AT_PARAM, String(started));
          window.location.replace(url.toString());
          return;
        }
      }
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
