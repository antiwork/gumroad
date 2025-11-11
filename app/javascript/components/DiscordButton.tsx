import * as React from "react";

import { joinServer, leaveServer } from "$app/data/discord_integration";
import { DISCORD_CLIENT_ID, DISCORD_OAUTH_URL } from "$app/utils/integrations";
import { startOauthRedirectChecker } from "$app/utils/oauth";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";

export const DiscordButton = ({
  purchaseId,
  connected,
  redirectSettings,
  customState,
}: {
  purchaseId: string;
  connected: boolean;
  redirectSettings?: { host: string; protocol: string };
  customState?: string;
}) => {
  const [discordConnected, setDiscordConnected] = React.useState(connected);
  const [loading, setLoading] = React.useState(false);

  const openJoinDiscordPopup = () => {
    if (discordConnected) return;
    setLoading(true);

    const url = new URL(DISCORD_OAUTH_URL);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", Routes.oauth_redirect_integrations_discord_index_url(redirectSettings));
    url.searchParams.set("scope", "identify guilds.join");
    url.searchParams.set("client_id", DISCORD_CLIENT_ID);
    if (customState) url.searchParams.set("state", customState);

    const oauthPopup = window.open(url, "discord", "popup=yes");

    startOauthRedirectChecker({
      oauthPopup,
      onSuccess: async (code) => {
        const response = await joinServer(code, purchaseId);
        if (response.ok) {
          showAlert(`You've been added to the Discord server #${response.serverName}!`, "success");
          setDiscordConnected(true);
        } else {
          showAlert("Could not join the Discord server, please try again.", "error");
        }
        setLoading(false);
      },
      onError: () => {
        showAlert("Could not join the Discord server, please try again.", "error");
        setLoading(false);
      },
      onPopupClose: () => setLoading(false),
    });
  };

  const leaveDiscord = async () => {
    if (!discordConnected) return;
    setLoading(true);

    const response = await leaveServer(purchaseId);
    if (response.ok) {
      showAlert(`You've left the Discord server #${response.serverName}.`, "success");
      setDiscordConnected(false);
    } else {
      showAlert("Could not leave the Discord server.", "error");
    }
    setLoading(false);
  };

  return loading ? (
    <div className="flex items-center">
      <LoadingSpinner className="size-8" />
    </div>
  ) : (
    <Button className="button-discord" onClick={discordConnected ? leaveDiscord : openJoinDiscordPopup}>
      {discordConnected ? "Leave Discord" : "Join Discord"}
    </Button>
  );
};
