import { Apple, Google, Stripe } from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import * as React from "react";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

export const SocialAuth = () => {
  const { is_gumroad_mobile_app } = usePage<{ is_gumroad_mobile_app?: boolean }>().props;
  const originalLocation = useOriginalLocation();
  const featureFlags = useFeatureFlags();

  const next = new URL(originalLocation).searchParams.get("next");
  const isSignupPage = new URL(originalLocation).pathname === "/signup";
  const showStripe = isSignupPage ? !featureFlags.disable_stripe_signup : true;

  return (
    <section className="flex flex-col gap-4 pb-12">
      {is_gumroad_mobile_app ? (
        <SocialAuthButton provider="apple" href={Routes.user_apple_omniauth_authorize_path({ referer: next })}>
          <Apple pack="brands" className="size-5" />
          Apple
        </SocialAuthButton>
      ) : null}
      <SocialAuthButton
        provider="google"
        href={Routes.user_google_oauth2_omniauth_authorize_path({ origin: next, x_auth_access_type: "read" })}
      >
        <Google pack="brands" className="size-5" />
        Google
      </SocialAuthButton>
      {showStripe ? (
        <SocialAuthButton
          provider="stripe"
          href={Routes.user_stripe_connect_omniauth_authorize_path({ referer: next })}
        >
          <Stripe pack="brands" className="size-5" />
          Stripe
        </SocialAuthButton>
      ) : null}
    </section>
  );
};
