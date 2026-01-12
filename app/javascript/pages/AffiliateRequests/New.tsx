import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Layout } from "$app/components/Profile/Layout";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";

type Props = {
  creator_profile: CreatorProfile;
  success: boolean;
  requester_has_existing_account: boolean;
  email_param: string | null;
};

const AffiliateRequestsNew = () => {
  const { creator_profile, success, requester_has_existing_account, email_param } = cast<Props>(usePage().props);

  const appDomain = useAppDomain();
  const loggedInUser = useLoggedInUser();

  const { data, setData, post, processing } = useForm({
    affiliate_request: {
      name: loggedInUser?.name || "",
      email: loggedInUser?.email || "",
      promotion_text: "",
    },
  });

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    post(Routes.custom_domain_create_affiliate_request_path());
  };

  const nameUID = React.useId();
  const emailUID = React.useId();
  const promotionUID = React.useId();

  const successEmail = email_param || data.affiliate_request.email;

  return (
    <Layout creatorProfile={creator_profile}>
      <PageHeader
        title={`Become an affiliate for ${creator_profile.name}`}
        className="mx-auto w-full max-w-6xl border-0 lg:px-0"
      />
      <form className="border-y border-border px-4 pt-8 lg:px-0" onSubmit={onSubmit}>
        <section className="mx-auto w-full max-w-6xl">
          <header>
            <div className="flex flex-col gap-4">
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
          {success ? (
            <Alert variant="success">
              <div className="flex flex-col gap-4">
                <p>Your request has been submitted! We will send you an email notification when you are approved.</p>
                {requester_has_existing_account ? null : (
                  <p>
                    In the meantime,{" "}
                    <a href={Routes.signup_url({ host: appDomain, email: successEmail })}>
                      create your Gumroad account
                    </a>{" "}
                    using email {successEmail} and confirm it. You'll receive your affiliate links once your Gumroad
                    account is active.
                  </p>
                )}
              </div>
            </Alert>
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
                    required
                    placeholder="Name"
                    value={data.affiliate_request.name}
                    onChange={(event) => setData("affiliate_request.name", event.target.value)}
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
                    type="email"
                    required
                    placeholder="Email"
                    value={data.affiliate_request.email}
                    onChange={(event) => setData("affiliate_request.email", event.target.value)}
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
                  value={data.affiliate_request.promotion_text}
                  onChange={(event) => setData("affiliate_request.promotion_text", event.target.value)}
                />
              </fieldset>
              <Button type="submit" color="accent" disabled={processing}>
                {processing ? "Submitting..." : "Submit affiliate request"}
              </Button>
            </>
          )}
        </section>
      </form>
    </Layout>
  );
};

AffiliateRequestsNew.loggedInUserLayout = true;
export default AffiliateRequestsNew;
