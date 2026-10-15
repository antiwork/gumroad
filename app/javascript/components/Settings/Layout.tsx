import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { SettingPage as Page } from "$app/parsers/settings";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useReactNativeMessage } from "$app/components/useReactNativeMessage";

const PAGE_TITLES = {
  main: "Settings",
  profile: "Profile",
  team: "Team",
  payments: "Payments",
  billing: "Billing",
  authorized_applications: "Applications",
  password: "Password and authentication",
  social_connections: "Social connections",
  third_party_analytics: "Third-party analytics",
  advanced: "Advanced",
};

const PAGE_PATHS: Record<Page, () => string> = {
  main: () => Routes.settings_main_path(),
  profile: () => Routes.settings_profile_path(),
  team: () => Routes.settings_team_path(),
  payments: () => Routes.settings_payments_path(),
  billing: () => Routes.settings_billing_path(),
  authorized_applications: () => Routes.settings_authorized_applications_path(),
  password: () => Routes.settings_password_path(),
  social_connections: () => Routes.settings_social_connections_path(),
  third_party_analytics: () => Routes.settings_third_party_analytics_path(),
  advanced: () => Routes.settings_advanced_path(),
};

type Props = {
  onSave?: () => void;
  pages: Page[];
  currentPage: Page;
  children: React.ReactNode;
  canUpdate?: boolean;
};

export const postToMobileApp = (message: object) => window.ReactNativeWebView?.postMessage(JSON.stringify(message));

export const Layout = ({ onSave, pages, currentPage, children, canUpdate }: Props) => {
  const isMobileAppWebView = Boolean(usePage<{ is_mobile_app_web_view?: boolean }>().props.is_mobile_app_web_view);

  useReactNativeMessage((data) => {
    if (data.type === "mobileAppSettingsSave") onSave?.();
  });

  const canSave = Boolean(onSave && canUpdate);
  React.useEffect(() => {
    if (!isMobileAppWebView) return;
    postToMobileApp({ type: "settingsCanUpdate", canUpdate: canSave });
  }, [isMobileAppWebView, canSave]);

  if (isMobileAppWebView) return <div>{children}</div>;

  return (
    <>
      <PageHeader
        className="sticky-top"
        title="Settings"
        actions={
          onSave ? (
            <Button color="accent" onClick={onSave} disabled={!canUpdate}>
              Update settings
            </Button>
          ) : null
        }
      >
        <Tabs>
          {pages.map((page) => (
            <Tab key={page} isSelected={currentPage === page} asChild>
              <Link href={PAGE_PATHS[page]()}>{PAGE_TITLES[page]}</Link>
            </Tab>
          ))}
        </Tabs>
      </PageHeader>
      <div>{children}</div>
    </>
  );
};
