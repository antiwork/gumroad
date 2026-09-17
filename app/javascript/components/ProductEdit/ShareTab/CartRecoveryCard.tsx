import { CartPlus } from "@boxicons/react";
import * as React from "react";

import { fetchCartRecovery, updateCartRecovery, type MarketingCartRecovery } from "$app/data/marketing_cart_recovery";
import { assertResponseError } from "$app/utils/request";

import { NavigationButton } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Pill } from "$app/components/ui/Pill";
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
      <header>
        <h2>Cart recovery</h2>
        <p className="text-muted">Bring back buyers who almost checked out. Nothing is sent until you turn this on.</p>
      </header>
      <Card>
        <CardContent details className="grid gap-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-3">
              <CartPlus className="size-6" />
              <span className="font-semibold">Abandoned cart email</span>
              {state.enabled ? (
                <Pill color="success" size="small">
                  On
                </Pill>
              ) : (
                <Pill size="small">Off</Pill>
              )}
            </div>
            <Switch
              checked={state.enabled}
              disabled={busy || !state.available}
              onChange={(event) => void setEnabled(event.target.checked)}
              label="Recover abandoned carts"
            />
          </div>

          {state.available ? (
            <>
              <span>
                Anyone who leaves this product in their cart gets &ldquo;{state.subject}&rdquo; {state.delay_hours}{" "}
                hours later. You can edit the email in Workflows.
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
            <Alert role="status">
              <span>{state.blocked_reason}</span>
            </Alert>
          )}
        </CardContent>
      </Card>
    </section>
  );
};
