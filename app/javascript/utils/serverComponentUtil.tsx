import * as React from "react";
import ReactDOMServer from "react-dom/server";
import { RouteObject } from "react-router-dom";
import { createStaticHandler, createStaticRouter } from "react-router-dom/server";
import { cast } from "ts-safe-cast";

import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import { DesignContextProvider, DesignSettings } from "$app/components/DesignSettings";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { FeatureFlagsProvider } from "$app/components/FeatureFlags";
import { LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import { SSRLocationProvider } from "$app/components/useOriginalLocation";
import { UserAgentProvider } from "$app/components/UserAgent";

// Parser for the react_on_rails railsContext (https://www.shakacode.com/react-on-rails/docs/guides/render-functions-and-railscontext/#rails-context)
export type GlobalProps = {
  design_settings: DesignSettings;
  domain_settings: {
    scheme: string;
    app_domain: string;
    root_domain: string;
    short_domain: string;
    discover_domain: string;
    third_party_analytics_domain: string;
  };
  user_agent_info: {
    is_mobile: boolean;
  };
  logged_in_user: unknown;
  current_seller: unknown;
  href: string;
  csp_nonce: string;
  locale: string;
  feature_flags: {
    require_email_typo_acknowledgment: boolean;
  };
};

// Use this function to wrap a React component for server-side rendering.
export const register =
  <Props extends object>({
    component,
    ssrComponent,
    propParser,
  }: {
    component: React.ComponentType<Props>;
    ssrComponent?: (global: GlobalProps) => Promise<React.ComponentType<Props>>;
    propParser: (data: unknown) => Props;
  }) =>
  (props: unknown, context: unknown) => {
    const global: GlobalProps = cast(context);
    const wrapper = (Component: React.ComponentType<Props>) => {
      const ssrComponent = () => {
        let parsedProps: Props;
        try {
          parsedProps = propParser(props);
        } catch (error) {
          // In production, a half-usable page with a broken react component might be better than an all-page error
          if (process.env.NODE_ENV !== "production") throw error;

          console.error(error); // eslint-disable-line no-console
          return <p>Something broke. We're looking into what happened. Sorry about this!</p>;
        }
        return (
          <React.StrictMode>
            <DesignContextProvider value={global.design_settings}>
              <DomainSettingsProvider
                value={{
                  scheme: global.domain_settings.scheme,
                  appDomain: global.domain_settings.app_domain,
                  rootDomain: global.domain_settings.root_domain,
                  shortDomain: global.domain_settings.short_domain,
                  discoverDomain: global.domain_settings.discover_domain,
                  thirdPartyAnalyticsDomain: global.domain_settings.third_party_analytics_domain,
                }}
              >
                <UserAgentProvider value={{ isMobile: global.user_agent_info.is_mobile, locale: global.locale }}>
                  <LoggedInUserProvider value={parseLoggedInUser(global.logged_in_user)}>
                    <CurrentSellerProvider value={parseCurrentSeller(global.current_seller)}>
                      <SSRLocationProvider value={global.href}>
                        <FeatureFlagsProvider value={global.feature_flags}>
                          <Component {...parsedProps} />
                        </FeatureFlagsProvider>
                      </SSRLocationProvider>
                    </CurrentSellerProvider>
                  </LoggedInUserProvider>
                </UserAgentProvider>
              </DomainSettingsProvider>
            </DesignContextProvider>
          </React.StrictMode>
        );
      };
      ssrComponent.displayName = "SSR component";
      return ssrComponent;
    };
    if (SSR) {
      const render = (component: React.ComponentType<Props>) => ReactDOMServer.renderToString(wrapper(component)());
      return ssrComponent ? ssrComponent(global).then(render) : Promise.resolve(render(component));
    }
    return wrapper(component);
  };

export const buildStaticRouter = async (global: GlobalProps, routes: RouteObject[]) => {
  const request = new Request(new URL(global.href));
  const handler = createStaticHandler(routes);
  const context = await handler.query(request);
  // eslint-disable-next-line @typescript-eslint/only-throw-error -- hacky, but handled correctly by the backend
  if (context instanceof Response) throw context;
  const router = createStaticRouter(routes, context);
  return { router, context };
};
