import * as React from "react";

export type FeatureFlags = {
  require_email_typo_acknowledgment: boolean;
  dashboard_spa_enabled: boolean;
};

const FeatureFlagsContext = React.createContext<FeatureFlags>({
  require_email_typo_acknowledgment: false,
  dashboard_spa_enabled: true,
});

export const FeatureFlagsProvider = FeatureFlagsContext.Provider;

export function useFeatureFlags() {
  return React.useContext(FeatureFlagsContext);
}
