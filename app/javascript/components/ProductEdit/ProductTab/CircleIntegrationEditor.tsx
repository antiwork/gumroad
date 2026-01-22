import * as React from "react";

import { CircleCommunity, CircleSpaceGroup, fetchCommunities, fetchSpaceGroups } from "$app/data/circle_integration";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Toggle } from "$app/components/Toggle";
import { Alert } from "$app/components/ui/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

export type CircleIntegration = {
  name: "circle";
  api_key: string;
  keep_inactive_members: boolean;
  integration_details: { community_id: string; space_group_id: string };
} | null;

type FetchState<T> = null | { status: "fetching" } | { status: "error" } | { status: "success"; data: T[] };

export const CircleIntegrationEditor = ({
  integration,
  onChange,
}: {
  integration: CircleIntegration;
  onChange: (integration: CircleIntegration) => void;
}) => {
  const uid = React.useId();

  const { product, updateProduct } = useProductEditContext();

  const [isEnabled, setIsEnabled] = React.useState(!!integration);

  const [apiKey, setApiKey] = React.useState(integration?.api_key ?? "");

  const [communities, setCommunities] = React.useState<FetchState<CircleCommunity>>(null);
  const [selectedCommunityId, setSelectedCommunityId] = React.useState<number | null>(
    integration ? parseInt(integration.integration_details.community_id, 10) : null,
  );
  const loadCommunities = async () => {
    if (apiKey) {
      setCommunities({ status: "fetching" });
      try {
        const response = await fetchCommunities(apiKey);
        setCommunities({ status: "success", data: response.communities });
      } catch (e) {
        assertResponseError(e);
        setCommunities({ status: "error" });
        showAlert("Không thể lấy cộng đồng từ Circle. Vui lòng kiểm tra API key của bạn.", "error");
      }
    }
  };
  useRunOnce(() => {
    if (apiKey) void loadCommunities();
  });

  const loadSpaceGroups = async () => {
    if (!apiKey || !selectedCommunityId) return;
    setSpaceGroups({ status: "fetching" });
    try {
      const response = await fetchSpaceGroups(apiKey, selectedCommunityId);
      setSpaceGroups({ status: "success", data: response.spaceGroups });
    } catch (e) {
      assertResponseError(e);
      setSpaceGroups({ status: "error" });
      showAlert("Không thể lấy nhóm không gian từ Circle. Vui lòng thử lại.", "error");
    }
  };

  React.useEffect(() => void loadSpaceGroups(), [selectedCommunityId]);

  const [spaceGroups, setSpaceGroups] = React.useState<FetchState<CircleSpaceGroup>>(null);
  const [selectedSpaceGroupId, setSelectedSpaceGroupId] = React.useState<number | null>(
    integration ? parseInt(integration.integration_details.space_group_id, 10) : null,
  );

  React.useEffect(() => {
    if (!apiKey || !selectedCommunityId || !selectedSpaceGroupId) return;
    onChange({
      name: "circle",
      api_key: apiKey,
      keep_inactive_members: false,
      integration_details: {
        community_id: selectedCommunityId.toString(),
        space_group_id: selectedSpaceGroupId.toString(),
      },
    });
  }, [selectedSpaceGroupId]);

  const setEnabledForOptions = (enabled: boolean) =>
    updateProduct((product) => {
      for (const variant of product.variants) variant.integrations = { ...variant.integrations, circle: enabled };
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
      label="Mời khách hàng của bạn vào cộng đồng Circle"
      dropdown={
        <div className="flex flex-col gap-4">
          Những người mua sản phẩm của bạn sẽ tự động được mời vào cộng đồng Circle của bạn. Để lấy API token,
          hãy truy cập your-community.circle.so/settings/API.
          <fieldset>
            <label htmlFor={`${uid}-api-key`}>API Token</label>
            <input
              id={`${uid}-api-key`}
              value={apiKey}
              onChange={(evt) => setApiKey(evt.target.value)}
              placeholder="Nhập hoặc dán API token của bạn"
            />
          </fieldset>
          <Button
            color="primary"
            onClick={() => {
              setSelectedCommunityId(null);
              setSpaceGroups(null);
              setSelectedSpaceGroupId(null);
              void loadCommunities();
            }}
            disabled={communities?.status === "fetching"}
          >
            {communities?.status === "success" ? "Cập nhật" : "Tải cộng đồng"}
          </Button>
          {communities ? (
            communities.status === "fetching" ? (
              <div className="flex justify-center">
                <LoadingSpinner />
              </div>
            ) : communities.status === "error" ? (
              <Alert variant="danger">Không thể lấy cộng đồng từ Circle. Vui lòng kiểm tra API key của bạn.</Alert>
            ) : (
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-community`}>Chọn một cộng đồng</label>
                </legend>
                <select
                  id={`${uid}-community`}
                  value={selectedCommunityId ?? "select-community"}
                  onChange={(ev) => setSelectedCommunityId(parseInt(ev.target.value, 10))}
                >
                  <option value="select-community" disabled>
                    Chọn một cộng đồng
                  </option>
                  {communities.data.map((community) => (
                    <option key={community.id} value={community.id}>
                      {community.name}
                    </option>
                  ))}
                </select>
              </fieldset>
            )
          ) : null}
          {spaceGroups ? (
            spaceGroups.status === "fetching" ? (
              <div className="flex justify-center">
                <LoadingSpinner />
              </div>
            ) : spaceGroups.status === "error" ? (
              <Alert variant="danger">Không thể lấy nhóm không gian từ Circle. Vui lòng thử lại.</Alert>
            ) : (
              <>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-space-group`}>Chọn một nhóm không gian</label>
                  </legend>
                  <select
                    id={`${uid}-space-group`}
                    value={selectedSpaceGroupId ?? "select-space-group"}
                    onChange={(ev) => {
                      setSelectedSpaceGroupId(parseInt(ev.target.value, 10));
                      setEnabledForOptions(true);
                    }}
                  >
                    <option value="select-space-group" disabled>
                      Chọn một nhóm không gian
                    </option>
                    {spaceGroups.data.map((spaceGroup) => (
                      <option key={spaceGroup.id} value={spaceGroup.id}>
                        {spaceGroup.name}
                      </option>
                    ))}
                  </select>
                </fieldset>
                {product.native_type === "membership" && integration ? (
                  <label>
                    <input
                      type="checkbox"
                      checked={integration.keep_inactive_members}
                      onChange={() =>
                        onChange({ ...integration, keep_inactive_members: !integration.keep_inactive_members })
                      }
                    />
                    Không xóa quyền truy cập Circle khi tư cách thành viên kết thúc
                  </label>
                ) : null}
                {product.variants.length > 0 ? (
                  <>
                    {product.variants.every(({ integrations }) => !integrations.circle) ? (
                      <Alert role="status" variant="warning">
                        {product.native_type === "membership"
                          ? "Tích hợp của bạn chưa được gán cho bất kỳ cấp bậc nào. Hãy kiểm tra cài đặt cấp bậc của bạn."
                          : "Tích hợp của bạn chưa được gán cho bất kỳ phiên bản nào. Hãy kiểm tra cài đặt phiên bản của bạn."}
                      </Alert>
                    ) : null}
                    <Toggle
                      value={product.variants.every(({ integrations }) => integrations.circle)}
                      onChange={setEnabledForOptions}
                    >
                      {product.native_type === "membership" ? "Kích hoạt cho tất cả các cấp bậc" : "Kích hoạt cho tất cả các phiên bản"}
                    </Toggle>
                  </>
                ) : null}
              </>
            )
          ) : null}
        </div>
      }
    />
  );
};
