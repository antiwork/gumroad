import * as React from "react";

import { startWaitlistEmail } from "$app/data/waitlist_email";
import { assertResponseError } from "$app/utils/request";

import { SaveThenOpenButton } from "$app/components/ProductEdit/ShareTab/SaveThenOpenButton";
import { EmailDeliveryState, Waitlist } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

const EMAIL_SUMMARY: Record<Exclude<EmailDeliveryState, "draft">, string> = {
  scheduled: "Your email to your waitlist is scheduled.",
  published: "Your waitlist email is published, but it wasn't emailed. You can send it from Emails.",
  sending: "Your email to your waitlist is on its way. Check delivery details in Emails.",
  waiting: "Your email to your waitlist is on its way. Check delivery details in Emails.",
  incomplete: "Your email to your waitlist hasn't finished sending. Check delivery details in Emails.",
  sent: "We finished sending your email to your waitlist. Check delivery details in Emails.",
  expired: "Your email to your waitlist wasn't sent. You can send it now from Emails.",
  abandoned: "Your email to your waitlist wasn't sent. You can send it now from Emails.",
  stopped: "Your email to your waitlist was stopped. Check delivery details in Emails.",
};

export const WaitlistCard = ({
  waitlist,
  productName,
  productPermalink,
}: {
  waitlist: Waitlist;
  productName: string;
  productPermalink: string;
}) => {
  const people = `${waitlist.count.toLocaleString()} ${waitlist.count === 1 ? "person" : "people"}`;

  const startEmail = async () => {
    try {
      return await startWaitlistEmail(productPermalink);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      return null;
    }
  };

  return (
    <section className="grid gap-4">
      <header>
        <h2>Your waitlist</h2>
      </header>
      <Card>
        <CardContent details className="grid gap-4">
          {waitlist.email ? (
            <>
              <p>
                {waitlist.email.state === "draft"
                  ? "Your email to your waitlist is a draft."
                  : EMAIL_SUMMARY[waitlist.email.state]}
              </p>
              {waitlist.blocked_reason ? <Alert role="status">{waitlist.blocked_reason}</Alert> : null}
              <div className="flex flex-wrap gap-2">
                <SaveThenOpenButton href={waitlist.email.edit_url}>
                  {waitlist.email.state === "draft" ? "Review the draft" : "Open in Emails"}
                </SaveThenOpenButton>
              </div>
            </>
          ) : (
            <>
              <p>
                <strong>{people}</strong> asked to hear when {productName} launches.
              </p>
              {waitlist.blocked_reason ? (
                <Alert role="status">{waitlist.blocked_reason}</Alert>
              ) : (
                <>
                  <div className="flex flex-wrap gap-2">
                    <SaveThenOpenButton color="primary" getHref={startEmail}>
                      Email your waitlist
                    </SaveThenOpenButton>
                  </div>
                  <small className="text-muted">
                    This starts a draft in Emails. Nothing is sent until you send it.
                  </small>
                </>
              )}
            </>
          )}
        </CardContent>
      </Card>
    </section>
  );
};
