import { Apple, Google, Stripe, TwitterX } from "@boxicons/react";
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
  const pathname = new URL(originalLocation).pathname.replace(/\/+/gu, "/").replace(/\/$/u, "");
  const isSignupPage = /^\/signup(\.html)?$/u.test(pathname);
  const showStripe = isSignupPage ? !featureFlags.disable_stripe_signup : true;
  // An account created with Apple in the app has no password its owner knows, so the web needs this way in.
  const showApple = is_gumroad_mobile_app || !isSignupPage;

  return (
    <section className="flex flex-col gap-4 pb-12">
      {showApple ? (
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
      <SocialAuthButton
        provider="twitter"
        href={Routes.user_twitter_omniauth_authorize_path({ referer: next, x_auth_access_type: "read" })}
      >
        <TwitterX pack="brands" className="size-5" /> X
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
