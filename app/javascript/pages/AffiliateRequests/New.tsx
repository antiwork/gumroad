import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Layout } from "$app/components/Profile/Layout";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Textarea } from "$app/components/ui/Textarea";

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
        <FormSection
          className="mx-auto w-full max-w-6xl"
          header={
            <>
              <p>
                Applying to be an affiliate is easy. Fill out the form below and let {creator_profile.name} know how
                you'll be promoting their products.
              </p>
              <p>
                To help speed up your approval, include things like social urls, audience size, audience engagement,
                etc...
              </p>
            </>
          }
        >
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
                <Fieldset>
                  <FieldsetTitle>
                    <Label htmlFor={nameUID}>Name</Label>
                  </FieldsetTitle>
                  <Input
                    id={nameUID}
                    type="text"
                    required
                    value={data.affiliate_request.name}
                    onChange={(event) => setData("affiliate_request.name", event.target.value)}
                  />
                </Fieldset>
              )}
              {loggedInUser?.email ? null : (
                <Fieldset>
                  <FieldsetTitle>
                    <Label htmlFor={emailUID}>Email</Label>
                  </FieldsetTitle>
                  <Input
                    id={emailUID}
                    type="email"
                    required
                    value={data.affiliate_request.email}
                    onChange={(event) => setData("affiliate_request.email", event.target.value)}
                  />
                </Fieldset>
              )}
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor={promotionUID}>Promotion</Label>
                </FieldsetTitle>
                <Textarea
                  id={promotionUID}
                  rows={5}
                  placeholder="How do you intend to promote their products? How big is your audience?"
                  value={data.affiliate_request.promotion_text}
                  onChange={(event) => setData("affiliate_request.promotion_text", event.target.value)}
                />
              </Fieldset>
              <Button type="submit" color="accent" disabled={processing}>
                {processing ? "Submitting..." : "Submit affiliate request"}
              </Button>
            </>
          )}
        </FormSection>
      </form>
    </Layout>
  );
};

AffiliateRequestsNew.loggedInUserLayout = true;
export default AffiliateRequestsNew;
