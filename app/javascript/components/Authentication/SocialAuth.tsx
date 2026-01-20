import * as React from "react";

import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

export const SocialAuth = () => {
  const originalLocation = useOriginalLocation();

  const next = new URL(originalLocation).searchParams.get("next");
  return (
    <div className="grid grid-cols-2 gap-4">
      <SocialAuthButton className="flex items-center justify-center py-3.5 border border-slate-100 rounded-2xl bg-white hover:bg-slate-50 hover:border-slate-200 transition-all text-slate-600 shadow-sm" provider="facebook" href={Routes.user_facebook_omniauth_authorize_path({ referer: next })}>
        <span className="text-xs font-bold">Facebook</span>
      </SocialAuthButton>
      <SocialAuthButton
        className="flex items-center justify-center py-3.5 border border-slate-100 rounded-2xl bg-white hover:bg-slate-50 hover:border-slate-200 transition-all text-slate-600 shadow-sm"
        provider="google"
        href={Routes.user_google_oauth2_omniauth_authorize_path({ referer: next, x_auth_access_type: "read" })}
      >
        <span className="text-xs font-bold">Google</span>
      </SocialAuthButton>
    </div>
  );
};
