import * as React from "react";

import { fetchServerInfo } from "$app/data/discord_integration";
import { DISCORD_CLIENT_ID, DISCORD_OAUTH_URL } from "$app/utils/integrations";
import { startOauthRedirectChecker } from "$app/utils/oauth";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Alert } from "$app/components/ui/Alert";
import { Switch } from "$app/components/ui/Switch";

export type DiscordIntegration = {
  keep_inactive_members: boolean;
  integration_details: { username: string; server_id: string; server_name: string };
} | null;

export const DiscordIntegrationEditor = ({
  integration,
  onChange,
}: {
  integration: DiscordIntegration;
  onChange: (integration: DiscordIntegration) => void;
}) => {
  const { product, updateProduct } = useProductEditContext();

  const [isLoading, setIsLoading] = React.useState(false);
  const [isEnabled, setIsEnabled] = React.useState(!!integration);

  const getDiscordUrl = () => {
    const url = new URL(DISCORD_OAUTH_URL);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", Routes.oauth_redirect_integrations_discord_index_url());
    url.searchParams.set("scope", "bot identify");
    url.searchParams.set("permissions", "268435459"); // MANAGE ROLE, KICK MEMBER, INVITE MEMBER
    url.searchParams.set("client_id", DISCORD_CLIENT_ID);

    return url.toString();
  };

  const setEnabledForOptions = (enabled: boolean) =>
    updateProduct((product) => {
      for (const variant of product.variants) variant.integrations = { ...variant.integrations, discord: enabled };
    });

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={(newValue) => {
        if (newValue) {
          setIsEnabled(true);
          setEnabledForOptions(true);
        } else {
          onChange(null);
          setIsEnabled(false);
          setEnabledForOptions(false);
        }
      }}
      label="Invite your customers to a Discord server"
      dropdown={
        <div className="flex flex-col gap-4">
          People who purchase your product will be automatically invited to your Discord server.
          {isLoading ? (
            <LoadingSpinner className="size-6" />
          ) : !integration ? (
            <div>
              <Button
                color="discord"
                onClick={() => {
                  setIsLoading(true);
                  const oauthPopup = window.open(getDiscordUrl(), "discord", "popup=yes");
                  startOauthRedirectChecker({
                    oauthPopup,
                    onSuccess: async (code) => {
                      const response = await fetchServerInfo(code);
                      if (response.ok) {
                        onChange({
                          keep_inactive_members: false,
                          integration_details: {
                            server_name: response.serverName,
                            server_id: response.serverId,
                            username: response.username,
                          },
                        });
                        setEnabledForOptions(true);
                      } else {
                        showAlert("Could not connect to your Discord account, please try again.", "error");
                      }
                      setIsLoading(false);
                    },
                    onError: () => {
                      showAlert("Could not connect to your Discord account, please try again.", "error");
                      setIsLoading(false);
                    },
                    onPopupClose: () => setIsLoading(false),
                  });
                }}
              >
                <span className="brand-icon brand-icon-discord" />
                Connect to Discord
              </Button>
            </div>
          ) : (
            <>
              <div>
                <b>Discord account #{integration.integration_details.username} connected</b>
                <div>Server name: {integration.integration_details.server_name}</div>
              </div>
              <div>
                <Button
                  color="danger"
                  onClick={() => {
                    setIsLoading(true);
                    onChange(null);
                    setIsLoading(false);
                  }}
                >
                  <span className="icon brand-icon-discord" />
                  Disconnect Discord
                </Button>
              </div>
              {product.variants.length > 0 ? (
                <>
                  {product.variants.every(({ integrations }) => !integrations.discord) ? (
                    <Alert role="status" variant="warning">
                      {product.native_type === "membership"
                        ? "Your integration is not assigned to any tier. Check your tiers' settings."
                        : "Your integration is not assigned to any version. Check your versions' settings."}
                    </Alert>
                  ) : null}
                  <Switch
                    checked={product.variants.every(({ integrations }) => integrations.discord)}
                    onChange={(e) => setEnabledForOptions(e.target.checked)}
                    label={product.native_type === "membership" ? "Enable for all tiers" : "Enable for all versions"}
                  />
                </>
              ) : null}
              {product.native_type === "membership" ? (
                <label>
                  <input
                    type="checkbox"
                    checked={integration.keep_inactive_members}
                    onChange={() =>
                      onChange({ ...integration, keep_inactive_members: !integration.keep_inactive_members })
                    }
                  />
                  Do not remove Discord access when membership ends
                </label>
              ) : null}
            </>
          )}
        </div>
      }
    />
  );
};
