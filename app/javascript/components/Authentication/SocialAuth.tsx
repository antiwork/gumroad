import * as React from "react";

import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import FirebaseGoogleLogin from "$app/components/Authentication/FirebaseGoogleLogin";
import DirectLoginButton from "$app/components/Authentication/DirectLoginButton";

export const SocialAuth = () => {
  const next = new URL(useOriginalLocation()).searchParams.get("next");
    return (
    <section className="paragraphs">
      <DirectLoginButton />
      <FirebaseGoogleLogin
        onSuccess={(userData) => {
          console.log("Firebase login successful:", userData);
        }}
        onError={(error) => {
          console.error("Firebase login error:", error);
        }}
      />
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
      <SocialAuthButton provider="stripe" href={Routes.user_stripe_connect_omniauth_authorize_path({ referer: next })}>
        Stripe
      </SocialAuthButton>
    </section>
  );
};
