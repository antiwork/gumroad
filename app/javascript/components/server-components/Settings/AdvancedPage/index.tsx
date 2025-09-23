import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { showAlert } from "$app/components/server-components/Alert";
import AccountDeletionSection from "$app/components/Settings/AdvancedPage/AccountDeletionSection";
import ApplicationsSection from "$app/components/Settings/AdvancedPage/ApplicationsSection";
import BlockEmailsSection from "$app/components/Settings/AdvancedPage/BlockEmailsSection";
import CustomDomainSection from "$app/components/Settings/AdvancedPage/CustomDomainSection";
import NotificationEndpointSection from "$app/components/Settings/AdvancedPage/NotificationEndpointSection";
import { Layout } from "$app/components/Settings/Layout";

export type Application = {
  id: string;
  name: string;
  icon_url: string | null;
};

type Props = {
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

const AdvancedPage = (props: Props) => {
  const [customDomain, setCustomDomain] = React.useState(props.custom_domain_name);
  const [pingEndpoint, setPingEndpoint] = React.useState(props.notification_endpoint);
  const [blockedEmails, setBlockedEmails] = React.useState(props.blocked_customer_emails);

  const handleSave = asyncVoid(async () => {
    try {
      const response = await request({
        url: Routes.settings_advanced_path(),
        method: "PUT",
        accept: "json",
        data: {
          domain: customDomain.trim(),
          blocked_customer_emails: blockedEmails,
          user: {
            notification_endpoint: pingEndpoint.trim(),
          },
        },
      });
      const responseData = cast<{ success: true } | { success: false; error_message: string }>(await response.json());
      if (!responseData.success) throw new ResponseError(responseData.error_message);
      showAlert("Your account has been updated!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  return (
    <Layout currentPage="advanced" pages={props.settings_pages} onSave={handleSave} canUpdate>
      <form>
        <CustomDomainSection
          verificationStatus={props.custom_domain_verification_status}
          customDomain={customDomain}
          setCustomDomain={setCustomDomain}
        />

        <BlockEmailsSection blockedEmails={blockedEmails} setBlockedEmails={setBlockedEmails} />

        <NotificationEndpointSection
          pingEndpoint={pingEndpoint}
          setPingEndpoint={setPingEndpoint}
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
};

export default register({ component: AdvancedPage, propParser: createCast() });
