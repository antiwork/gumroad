import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { formatPrice } from "$app/utils/price";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

type PageProps = {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
  referrer: {
    id: string;
    name: string;
  } | null;
  stats: {
    number_of_creators: number;
    total_made: number;
  };
};

function SignupPage() {
  const { email: initialEmail, application_name, recaptcha_site_key, referrer, stats } = usePage<PageProps>().props;
  const { number_of_creators, total_made } = stats;

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();

  const form = useForm<{
    user: {
      email: string;
      password: string;
      terms_accepted: boolean;
    };
    next: string | null;
    referral: string | null;
    "g-recaptcha-response": string | null;
  }>({
    user: {
      email: initialEmail ?? "",
      password: "",
      terms_accepted: true,
    },
    next,
    referral: referrer?.id ?? null,
    "g-recaptcha-response": null,
  });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      form.transform((data) => ({
        ...data,
        "g-recaptcha-response": recaptchaResponse,
      }));
      form.post(Routes.signup_path());
    } catch (e) {
      if (e instanceof RecaptchaCancelledError) return;
      throw e;
    }
  };

  const headerText = referrer
    ? `Join ${referrer.name} on Gumroad`
    : application_name
      ? `Sign up for Gumroad and connect ${application_name}`
      : `Join over ${number_of_creators.toLocaleString()} creators who have earned over ${formatPrice("$", total_made, 0, { noCentsIfWhole: true })} on Gumroad selling digital products and memberships.`;

  return (
    <Layout header={<h1>{headerText}</h1>} headerActions={<Link href={Routes.login_path({ next })}>Log in</Link>}>
      <form onSubmit={(e) => void handleSubmit(e)}>
        <SocialAuth />
        <Separator>
          <span>or</span>
        </Separator>
        <section>
          <AuthAlert />
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-email`}>Email</label>
            </legend>
            <input
              id={`${uid}-email`}
              type="email"
              value={form.data.user.email}
              onChange={(e) => form.setData("user.email", e.target.value)}
              required
            />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-password`}>Password</label>
            </legend>
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              required
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Creating..." : "Create account"}
          </Button>
          <p>
            You agree to our <a href="https://gumroad.com/terms">Terms of Use</a> and{" "}
            <a href="https://gumroad.com/privacy">Privacy Policy</a>.
          </p>
        </section>
      </form>
      {recaptcha.container}
    </Layout>
  );
}

SignupPage.disableLayout = true;
export default SignupPage;
