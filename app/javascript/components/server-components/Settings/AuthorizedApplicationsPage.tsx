import { parseISO } from "date-fns";
import * as React from "react";
import { createCast, cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout } from "$app/components/Settings/Layout";
import { useUserAgentInfo } from "$app/components/UserAgent";

import placeholderAppIcon from "$assets/images/gumroad_app.png";

type AuthorizedApplication = {
  name: string;
  scopes: readonly Scope[];
  icon_url: string | null;
  is_own_app: boolean;
  first_authorized_at: string;
  id: string;
};

type Scope =
  | "edit_products"
  | "ifttt"
  | "mark_sales_as_shipped"
  | "refund_sales"
  | "unfurl"
  | "view_profile"
  | "view_public"
  | "view_sales"
  | "view_payouts"
  | "revenue_share"
  | "mobile_api"
  | "creator_api";

const SCOPE_DESCRIPTIONS: Record<Scope, string> = {
  edit_products: "Create new products and edit your existing products.",
  ifttt: "See your sales data.",
  mark_sales_as_shipped: "Mark your sales as shipped.",
  refund_sales: "Refund your sales.",
  unfurl: "Fetch public information of any product to preview it in Notion.",
  view_profile: "See your profile data.",
  view_public: "See your public information (name, Facebook profile, bio, Twitter handle).",
  view_sales: "See your sales data.",
  view_payouts: "See your payouts data.",
  revenue_share: "Revenue Share",
  mobile_api: "Mobile API",
  creator_api: "Creator API",
};

type Props = {
  settings_pages: SettingPage[];
  authorized_applications: AuthorizedApplication[];
};

const AuthorizedApplicationsPage = (props: Props) => {
  const userAgentInfo = useUserAgentInfo();
  const [applications, setApplications] = React.useState(props.authorized_applications);
  const [revokingAccessForApp, setRevokingAccessForApp] = React.useState<{ id: string; revoking?: boolean } | null>(
    null,
  );

  const handleRevokeAccess = asyncVoid(async (id: string) => {
    setRevokingAccessForApp({ id, revoking: true });
    try {
      const response = await request({
        url: Routes.oauth_authorized_application_path(id),
        method: "DELETE",
        accept: "json",
      });
      const responseData = cast<{ success: boolean; message: string }>(await response.json());

      if (responseData.success) {
        showAlert(responseData.message, "success");
        setApplications((prevApplications) => prevApplications.filter((application) => application.id !== id));
      } else {
        showAlert(responseData.message, "error");
      }
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
    setRevokingAccessForApp(null);
  });

  return (
    <Layout currentPage="authorized_applications" pages={props.settings_pages}>
      {applications.length > 0 ? (
        <section className="!p-4 md:!p-8">
          <table>
            <caption>You've authorized the following applications to use your Gumroad account.</caption>
            <tbody>
              {applications.map((application) => (
                <tr key={application.id}>
                  <td>
                    <div style={{ display: "flex", gap: "var(--spacer-3)" }}>
                      <div>
                        <img
                          src={application.icon_url || placeholderAppIcon}
                          className="application-icon"
                          width={72}
                          height={72}
                          alt={application.name}
                        />
                      </div>
                      <div>
                        <h3 style={{ marginBottom: "var(--spacer-1)" }}>
                          {application.name}
                          {application.is_own_app ? <span> (Your application)</span> : null}
                        </h3>

                        <p>
                          <small>
                            First authorized on:{" "}
                            {parseISO(application.first_authorized_at).toLocaleDateString(userAgentInfo.locale, {
                              month: "long",
                              day: "numeric",
                              year: "numeric",
                            })}
                          </small>
                        </p>
                      </div>
                    </div>
                  </td>
                  <td>
                    <ul>
                      {application.scopes.map((scope) => (
                        <li key={scope}>{SCOPE_DESCRIPTIONS[scope]}</li>
                      ))}
                    </ul>
                  </td>
                  <td>
                    <Button color="danger" outline onClick={() => setRevokingAccessForApp({ id: application.id })}>
                      <Icon name="x-square"></Icon>
                      Revoke access
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {revokingAccessForApp ? (
            <Modal
              open
              allowClose={!revokingAccessForApp.revoking}
              title="Revoke access"
              onClose={() => {
                setRevokingAccessForApp(null);
              }}
              footer={
                <>
                  <Button onClick={() => setRevokingAccessForApp(null)}>Cancel</Button>
                  <Button
                    color="danger"
                    disabled={revokingAccessForApp.revoking}
                    onClick={() => handleRevokeAccess(revokingAccessForApp.id)}
                  >
                    {revokingAccessForApp.revoking ? "Revoking access..." : "Yes, revoke access"}
                  </Button>
                </>
              }
            >
              <p>
                Are you sure you want to revoke access to{" "}
                {applications.find((app) => app.id === revokingAccessForApp.id)?.name ?? ""}?
              </p>
            </Modal>
          ) : null}
        </section>
      ) : (
        <div className="p-4 md:p-8">
          <div className="placeholder">
            <h3>Your account doesn't have any authorized applications.</h3>
            <p>Applications authorized to access your Gumroad account on your behalf will appear here.</p>
          </div>
        </div>
      )}
    </Layout>
  );
};
export default register({ component: AuthorizedApplicationsPage, propParser: createCast() });
