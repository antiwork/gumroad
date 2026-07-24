import * as React from "react";

export type FeatureFlags = {
  disable_stripe_signup: boolean;
};

const FeatureFlagsContext = React.createContext<FeatureFlags>({
  disable_stripe_signup: false,
});

export const FeatureFlagsProvider = FeatureFlagsContext.Provider;

export function useFeatureFlags() {
  return React.useContext(FeatureFlagsContext);
}
