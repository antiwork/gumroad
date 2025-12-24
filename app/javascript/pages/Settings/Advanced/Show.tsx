import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { type SettingPage } from "$app/parsers/settings";

import AccountDeletionSection from "$app/components/Settings/AdvancedPage/AccountDeletionSection";
import ApplicationsSection, { type Application } from "$app/components/Settings/AdvancedPage/ApplicationsSection";
import BlockEmailsSection from "$app/components/Settings/AdvancedPage/BlockEmailsSection";
import CustomDomainSection from "$app/components/Settings/AdvancedPage/CustomDomainSection";
import NotificationEndpointSection from "$app/components/Settings/AdvancedPage/NotificationEndpointSection";
import { Layout } from "$app/components/Settings/Layout";

type AdvancedPageProps = {
  settings_pages: SettingPage[];
  user_id: string;
  notification_endpoint: string;
  blocked_customer_emails: string;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  custom_domain_name: string;
  applications: Application[];
  allow_deactivation: boolean;
  formatted_balance_to_forfeit_on_account_deletion: string | null;
};

export default function AdvancedPage() {
  const props = cast<AdvancedPageProps>(usePage().props);
  const form = useForm({
    domain: props.custom_domain_name,
    blocked_customer_emails: props.blocked_customer_emails,
    user: {
      notification_endpoint: props.notification_endpoint,
    },
  });

  const handleSave = () => {
    form.transform((data) => ({
      ...data,
      domain: data.domain.trim(),
      user: {
        ...data.user,
        notification_endpoint: data.user.notification_endpoint.trim(),
      },
    }));

    form.put(Routes.settings_advanced_path(), {
      preserveScroll: true,
    });
  };

  return (
    <Layout currentPage="advanced" pages={props.settings_pages} onSave={handleSave} canUpdate={!form.processing}>
      <form>
        <CustomDomainSection
          verificationStatus={props.custom_domain_verification_status}
          customDomain={form.data.domain}
          setCustomDomain={(value) => form.setData("domain", value)}
        />

        <BlockEmailsSection
          blockedEmails={form.data.blocked_customer_emails}
          setBlockedEmails={(value) => form.setData("blocked_customer_emails", value)}
        />

        <NotificationEndpointSection
          pingEndpoint={form.data.user.notification_endpoint}
          setPingEndpoint={(value) => form.setData("user.notification_endpoint", value)}
          userId={props.user_id}
        />

        <ApplicationsSection applications={props.applications} />

        {props.allow_deactivation ? (
          <AccountDeletionSection
            formatted_balance_to_forfeit_on_account_deletion={props.formatted_balance_to_forfeit_on_account_deletion}
          />
        ) : null}
      </form>
    </Layout>
  );
}
