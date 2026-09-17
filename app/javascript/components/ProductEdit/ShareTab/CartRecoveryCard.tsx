import * as React from "react";

import { fetchCartRecovery, updateCartRecovery, type MarketingCartRecovery } from "$app/data/marketing_cart_recovery";
import { assertResponseError } from "$app/utils/request";

import { NavigationButton } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Switch } from "$app/components/ui/Switch";

export const CartRecoveryCard = ({ productPermalink }: { productPermalink: string }) => {
  const [state, setState] = React.useState<MarketingCartRecovery | null>(null);
  const [busy, setBusy] = React.useState(false);

  React.useEffect(() => {
    void fetchCartRecovery(productPermalink)
      .then(setState)
      .catch((e: unknown) => {
        assertResponseError(e);
      });
  }, [productPermalink]);

  if (state === null) return null;

  const setEnabled = async (enabled: boolean) => {
    setBusy(true);
    try {
      setState(await updateCartRecovery(productPermalink, enabled));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setBusy(false);
  };

  return (
    <section className="grid gap-4">
      <Card>
        <CardContent details className="grid gap-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2>Abandoned cart email</h2>
            <Switch
              checked={state.enabled}
              disabled={busy || !state.available}
              onChange={(event) => void setEnabled(event.target.checked)}
              aria-label="Abandoned cart email"
            />
          </div>

          {state.available ? (
            <>
              <span>
                {state.enabled ? "Sending" : "Turn this on to send"} &ldquo;{state.subject}&rdquo; to anyone who leaves
                this product in their cart, {state.delay_hours} hours later.
                {state.workflow_url ? null : " Once enabled, you can edit the email in Workflows."}
              </span>
              {state.account_wide ? (
                <small className="text-muted">
                  This is your account-wide cart reminder, which covers every product. Turning it off here pauses it for
                  all of them.
                </small>
              ) : null}
              {state.workflow_url ? (
                <div className="flex flex-wrap gap-2">
                  <NavigationButton href={state.workflow_url}>Open in Workflows</NavigationButton>
                </div>
              ) : null}
            </>
          ) : (
            <p role="status" className="text-muted">
              {state.blocked_reason}
            </p>
          )}
        </CardContent>
      </Card>
    </section>
  );
};
