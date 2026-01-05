import React from "react";

import { DesignContextProvider, DesignSettings } from "$app/components/DesignSettings";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { FeatureFlags, FeatureFlagsProvider } from "$app/components/FeatureFlags";
import { SSRLocationProvider } from "$app/components/useOriginalLocation";
import { UserAgentProvider } from "$app/components/UserAgent";

type GlobalProps = {
  design_settings: DesignSettings;
  domain_settings: {
    scheme: string;
    app_domain: string;
    root_domain: string;
    short_domain: string;
    discover_domain: string;
    third_party_analytics_domain: string;
    api_domain: string;
  };
  user_agent_info: {
    is_mobile: boolean;
  };
  href: string;
  locale: string;
  feature_flags: FeatureFlags;
};

export default function AppWrapper({ children, global }: { children: React.ReactNode; global: GlobalProps }) {
  return (
    <DesignContextProvider value={global.design_settings}>
      <DomainSettingsProvider
        value={{
          scheme: global.domain_settings.scheme,
          appDomain: global.domain_settings.app_domain,
          rootDomain: global.domain_settings.root_domain,
          shortDomain: global.domain_settings.short_domain,
          discoverDomain: global.domain_settings.discover_domain,
          thirdPartyAnalyticsDomain: global.domain_settings.third_party_analytics_domain,
          apiDomain: global.domain_settings.api_domain,
        }}
      >
        <UserAgentProvider
          value={{
            isMobile: global.user_agent_info.is_mobile,
            locale: global.locale,
          }}
        >
          <FeatureFlagsProvider value={global.feature_flags}>
            <SSRLocationProvider value={global.href}>{children}</SSRLocationProvider>
          </FeatureFlagsProvider>
        </UserAgentProvider>
      </DomainSettingsProvider>
    </DesignContextProvider>
  );
}
