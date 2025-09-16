import * as React from "react";
import { createCast } from "ts-safe-cast";

import { submitAffiliateRequest } from "$app/data/affiliate_request";
import { CreatorProfile } from "$app/parsers/profile";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Layout } from "$app/components/Profile/Layout";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";

type FormStatus =
  | { type: "initial" }
  | { type: "submitting" }
  | { type: "success"; requesterHasExistingAccount: boolean }
  | { type: "error"; message: string };

type Props = { creator_profile: CreatorProfile };

const AffiliateRequestPage = ({ creator_profile }: Props) => {
  const appDomain = useAppDomain();
  const loggedInUser = useLoggedInUser();

  const [name, setName] = React.useState(loggedInUser?.name || "");
  const [email, setEmail] = React.useState(loggedInUser?.email || "");
  const [promotionText, setPromotionText] = React.useState<string>("");
  const [formStatus, setFormStatus] = React.useState<FormStatus>({ type: "initial" });

  const onSubmit = asyncVoid(async () => {
    setFormStatus({ type: "submitting" });
    try {
      const response = await submitAffiliateRequest({ name, email, promotion_text: promotionText });
      setFormStatus({
        type: "success",
        requesterHasExistingAccount: response.requester_has_existing_account,
      });
    } catch (e) {
      assertResponseError(e);
      const message = `An error occurred while submitting affiliate request${e.message}`;
      showAlert(message, "error");
      setFormStatus({ type: "error", message });
    }
  });

  const nameUID = React.useId();
  const emailUID = React.useId();
  const promotionUID = React.useId();

  return (
    <Layout creatorProfile={creator_profile}>
      <PageHeader title={`Become an affiliate for ${creator_profile.name}`} />
      <form className="border-b border-border pt-8">
        <section>
          <header>
            <div className="paragraphs">
              <p>
                Applying to be an affiliate is easy. Fill out the form below and let {creator_profile.name} know how
                you'll be promoting their products.
              </p>
              <p>
                To help speed up your approval, include things like social urls, audience size, audience engagement,
                etc...
              </p>
            </div>
          </header>
          {formStatus.type === "success" ? (
            <div role="alert" className="success">
              <div className="paragraphs">
                <p>Your request has been submitted! We will send you an email notification when you are approved.</p>
                {formStatus.requesterHasExistingAccount ? null : (
                  <p>
                    In the meantime,{" "}
                    <a href={Routes.signup_url({ host: appDomain, email })}>create your Gumroad account</a> using email{" "}
                    {email} and confirm it. You'll receive your affiliate links once your Gumroad account is active.
                  </p>
                )}
              </div>
            </div>
          ) : (
            <>
              {loggedInUser?.name ? null : (
                <fieldset>
                  <legend>
                    <label htmlFor={nameUID}>Name</label>
                  </legend>
                  <input
                    id={nameUID}
                    type="text"
                    placeholder="Name"
                    value={name}
                    onChange={(event) => setName(event.target.value)}
                  />
                </fieldset>
              )}
              {loggedInUser?.email ? null : (
                <fieldset>
                  <legend>
                    <label htmlFor={emailUID}>Email</label>
                  </legend>
                  <input
                    id={emailUID}
                    type="text"
                    placeholder="Email"
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                  />
                </fieldset>
              )}
              <fieldset>
                <legend>
                  <label htmlFor={promotionUID}>Promotion</label>
                </legend>
                <textarea
                  id={promotionUID}
                  rows={5}
                  placeholder="How do you intend to promote their products? How big is your audience?"
                  value={promotionText}
                  onChange={(event) => setPromotionText(event.target.value)}
                />
              </fieldset>
              <Button color="accent" onClick={onSubmit} disabled={formStatus.type === "submitting"}>
                {formStatus.type === "submitting" ? "Submitting..." : "Submit affiliate request"}
              </Button>
            </>
          )}
        </section>
      </form>
    </Layout>
  );
};

export default register({ component: AffiliateRequestPage, propParser: createCast() });
