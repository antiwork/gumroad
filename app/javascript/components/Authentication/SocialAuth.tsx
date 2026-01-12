import * as React from "react";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

export const SocialAuth = () => {
  const originalLocation = useOriginalLocation();
  const featureFlags = useFeatureFlags();

  const next = new URL(originalLocation).searchParams.get("next");
  const isSignupPage = new URL(originalLocation).pathname === "/signup";
  const showStripe = isSignupPage ? !featureFlags.disable_stripe_signup : true;
  return (
    <section className="flex flex-col gap-4">
      <SocialAuthButton provider="facebook" href={Routes.user_facebook_omniauth_authorize_path({ referer: next })}>
        Facebook
      </SocialAuthButton>
      <SocialAuthButton
        provider="google"
        href={Routes.user_google_oauth2_omniauth_authorize_path({ referer: next, x_auth_access_type: "read" })}
      >
        Google
      </SocialAuthButton>
      <SocialAuthButton
        provider="twitter"
        href={Routes.user_twitter_omniauth_authorize_path({ referer: next, x_auth_access_type: "read" })}
      >
        X
      </SocialAuthButton>
      {showStripe ? (
        <SocialAuthButton
          provider="stripe"
          href={Routes.user_stripe_connect_omniauth_authorize_path({ referer: next })}
        >
          Stripe
        </SocialAuthButton>
      ) : null}
    </section>
  );
};
