import * as React from "react";

import { fetchCartRecovery, updateCartRecovery, type MarketingCartRecovery } from "$app/data/marketing_cart_recovery";
import emailStyles from "$app/entrypoints/email.scss?inline";
import { classNames } from "$app/utils/classNames";
import { assertResponseError } from "$app/utils/request";
import { sanitizeHtml } from "$app/utils/sanitize";

import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { LinkButton } from "$app/components/ui/LinkButton";
import { Switch } from "$app/components/ui/Switch";

const EmailPreview = ({ message }: { message: string }) => {
  const [height, setHeight] = React.useState(320);
  const observer = React.useRef<ResizeObserver | null>(null);
  React.useEffect(() => () => observer.current?.disconnect(), []);
  const html = React.useMemo(
    () =>
      `<!doctype html><html><head><meta name="viewport" content="width=device-width"><style>${emailStyles}</style></head><body><div class="email"><div class="main"><div>${sanitizeHtml(message)}</div></div></div></body></html>`,
    [message],
  );

  return (
    <iframe
      title="Email preview"
      sandbox="allow-same-origin"
      srcDoc={html}
      className="w-full border-0"
      style={{ height }}
      onLoad={(event) => {
        observer.current?.disconnect();
        const body = event.currentTarget.contentDocument?.body;
        if (!body) return;
        observer.current = new ResizeObserver(() => setHeight(Math.min(body.scrollHeight, 512)));
        observer.current.observe(body);
      }}
    />
  );
};

export const CartRecoveryCard = ({ productPermalink }: { productPermalink: string }) => {
  const [state, setState] = React.useState<MarketingCartRecovery | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [failed, setFailed] = React.useState(false);
  const [retry, setRetry] = React.useState(0);
  const switchId = React.useId();

  React.useEffect(() => {
    let current = true;
    setState(null);
    setFailed(false);
    void fetchCartRecovery(productPermalink)
      .then((result) => {
        if (current) setState(result);
      })
      .catch(() => {
        if (current) setFailed(true);
      });
    return () => {
      current = false;
    };
  }, [productPermalink, retry]);

  const setEnabled = async (enabled: boolean) => {
    setBusy(true);
    try {
      setState(await updateCartRecovery(productPermalink, enabled));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setBusy(false);
    }
  };

  const workflow = state?.workflows[0];

  return (
    <section aria-busy={busy || (!state && !failed)}>
      <Card>
        <CardContent details className="grid min-h-60 content-start justify-stretch gap-3">
          <div className="flex items-center justify-between gap-3">
            <h2>
              {state?.can_toggle ? (
                <label htmlFor={switchId} className="flex min-h-11 cursor-pointer items-center">
                  Abandoned cart email
                </label>
              ) : (
                "Abandoned cart email"
              )}
            </h2>
            {state?.can_toggle ? (
              <div
                className={classNames(
                  "flex shrink-0 items-center [&>label]:flex [&>label]:min-h-11 [&>label]:min-w-11 [&>label]:items-center [&>label]:justify-center",
                  busy && "[&_input]:opacity-100 [&>label]:opacity-100",
                )}
              >
                <Switch
                  id={switchId}
                  checked={state.enabled}
                  disabled={busy || (!state.available && !state.enabled)}
                  onChange={(event) => void setEnabled(event.target.checked)}
                  aria-describedby={`${switchId}-description`}
                />
              </div>
            ) : null}
          </div>
          {!state ? (
            failed ? (
              <p role="status">
                Could not load cart recovery.{" "}
                <LinkButton onClick={() => setRetry((value) => value + 1)}>Try again</LinkButton>
              </p>
            ) : (
              <p role="status" className="text-muted">
                Loading cart recovery…
              </p>
            )
          ) : state.can_toggle ? (
            <>
              <p id={`${switchId}-description`}>
                Email buyers {state.delay_hours} hours after they leave this product in their cart.
              </p>
              {!state.available ? (
                <p role="status" className="text-muted">
                  {state.blocked_reason}
                </p>
              ) : null}
              {state.message ? (
                <Details>
                  <DetailsToggle className="min-h-10">Preview email</DetailsToggle>
                  <div className="grid gap-4 rounded border border-border p-4">
                    <strong className="wrap-anywhere">{state.subject}</strong>
                    <EmailPreview message={state.message} />
                  </div>
                </Details>
              ) : null}
              <div className="flex min-h-10 items-center">
                {busy ? (
                  <span role="status">{state.enabled ? "Pausing…" : "Turning on…"}</span>
                ) : workflow ? (
                  <a href={workflow.url}>Edit email</a>
                ) : (
                  <span className="text-muted">You can edit this email after enabling it.</span>
                )}
              </div>
            </>
          ) : (
            <>
              <p id={`${switchId}-description`}>
                Manage these reminders in Workflows. Changes can affect other products or versions.
              </p>
              <ul className="grid gap-4">
                {state.workflows.map((item) => (
                  <li key={item.url} className="grid gap-1">
                    <a href={item.url} className="flex min-h-10 w-fit items-center wrap-anywhere">
                      {item.name}
                    </a>
                    <p className="wrap-anywhere text-muted">
                      {item.enabled ? "On" : "Off"} · {item.scope}
                    </p>
                  </li>
                ))}
              </ul>
            </>
          )}
        </CardContent>
      </Card>
    </section>
  );
};
