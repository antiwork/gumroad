import React from "react";

import { DomainSettings } from "$app/types/domain_settings";
import { LoggedInUser, Seller, CurrentUser } from "$app/types/user";

import { DesignContextProvider, DesignSettings } from "$app/components/DesignSettings";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert, { AlertPayload } from "$app/components/server-components/Alert";
import { SSRLocationProvider } from "$app/components/useOriginalLocation";
import { UserAgentProvider } from "$app/components/UserAgent";

type CardType = {
  id: string;
  name: string;
};

export type GlobalProps = {
  design_settings: DesignSettings;
  domain_settings: DomainSettings;
  user_agent_info: {
    is_mobile: boolean;
  };
  logged_in_user: LoggedInUser;
  current_seller: Seller;
  href: string;
  locale: string;
  title: string;
  current_user: CurrentUser;
  card_types: CardType[];
  flash: AlertPayload | null;
};

const AdminAppWrapper = ({ children, global }: { children: React.ReactNode; global: GlobalProps }) => (
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
        <LoggedInUserProvider value={parseLoggedInUser(global.logged_in_user)}>
          <SSRLocationProvider value={global.href}>
            <Alert initial={global.flash} />

            {children}
          </SSRLocationProvider>
        </LoggedInUserProvider>
      </UserAgentProvider>
    </DomainSettingsProvider>
  </DesignContextProvider>
);

export default AdminAppWrapper;
