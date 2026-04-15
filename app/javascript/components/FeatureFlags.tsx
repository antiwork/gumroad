import * as React from "react";

export type FeatureFlags = {
  require_email_typo_acknowledgment: boolean;
  disable_stripe_signup: boolean;
};

const FeatureFlagsContext = React.createContext<FeatureFlags>({
  require_email_typo_acknowledgment: false,
  disable_stripe_signup: false,
});

export const FeatureFlagsProvider = FeatureFlagsContext.Provider;

export function useFeatureFlags() {
  return React.useContext(FeatureFlagsContext);
}
