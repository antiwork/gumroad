import * as React from "react";

import { fetchServerInfo } from "$app/data/discord_integration";
import { DISCORD_CLIENT_ID, DISCORD_OAUTH_URL } from "$app/utils/integrations";
import { startOauthRedirectChecker } from "$app/utils/oauth";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Toggle } from "$app/components/Toggle";
import { Alert } from "$app/components/ui/Alert";

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
      label="Mời khách hàng của bạn vào máy chủ Discord"
      dropdown={
        <div className="flex flex-col gap-4">
          Những người mua sản phẩm của bạn sẽ tự động được mời vào máy chủ Discord của bạn.
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
                        showAlert("Không thể kết nối với tài khoản Discord của bạn, vui lòng thử lại.", "error");
                      }
                      setIsLoading(false);
                    },
                    onError: () => {
                      showAlert("Không thể kết nối với tài khoản Discord của bạn, vui lòng thử lại.", "error");
                      setIsLoading(false);
                    },
                    onPopupClose: () => setIsLoading(false),
                  });
                }}
              >
                <span className="brand-icon brand-icon-discord" />
                Kết nối với Discord
              </Button>
            </div>
          ) : (
            <>
              <div>
                <b>Tài khoản Discord #{integration.integration_details.username} đã kết nối</b>
                <div>Tên máy chủ: {integration.integration_details.server_name}</div>
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
                  Ngắt kết nối Discord
                </Button>
              </div>
              {product.variants.length > 0 ? (
                <>
                  {product.variants.every(({ integrations }) => !integrations.discord) ? (
                    <Alert role="status" variant="warning">
                      {product.native_type === "membership"
                        ? "Tích hợp của bạn chưa được gán cho bất kỳ cấp bậc nào. Hãy kiểm tra cài đặt cấp bậc của bạn."
                        : "Tích hợp của bạn chưa được gán cho bất kỳ phiên bản nào. Hãy kiểm tra cài đặt phiên bản của bạn."}
                    </Alert>
                  ) : null}
                  <Toggle
                    value={product.variants.every(({ integrations }) => integrations.discord)}
                    onChange={setEnabledForOptions}
                  >
                    {product.native_type === "membership" ? "Kích hoạt cho tất cả các cấp bậc" : "Kích hoạt cho tất cả các phiên bản"}
                  </Toggle>
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
                  Không xóa quyền truy cập Discord khi tư cách thành viên kết thúc
                </label>
              ) : null}
            </>
          )}
        </div>
      }
    />
  );
};
