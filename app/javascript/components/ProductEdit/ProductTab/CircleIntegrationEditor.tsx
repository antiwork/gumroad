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
        showAlert("Could not retrieve communities from Circle. Please check your API key.", "error");
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
      showAlert("Could not retrieve space groups from Circle. Please try again.", "error");
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
      label="Invite your customers to a Circle community"
      dropdown={
        <div className="flex flex-col gap-4">
          People who purchase your product will be automatically invited to your Circle community. To get your API
          token, visit your-community.circle.so/settings/API.
          <fieldset>
            <label htmlFor={`${uid}-api-key`}>API Token</label>
            <input
              id={`${uid}-api-key`}
              value={apiKey}
              onChange={(evt) => setApiKey(evt.target.value)}
              placeholder="Type or paste your API token"
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
            {communities?.status === "success" ? "Update" : "Load communities"}
          </Button>
          {communities ? (
            communities.status === "fetching" ? (
              <div className="flex justify-center">
                <LoadingSpinner />
              </div>
            ) : communities.status === "error" ? (
              <Alert variant="danger">Could not retrieve communities from Circle. Please check your API key.</Alert>
            ) : (
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-community`}>Select a community</label>
                </legend>
                <select
                  id={`${uid}-community`}
                  value={selectedCommunityId ?? "select-community"}
                  onChange={(ev) => setSelectedCommunityId(parseInt(ev.target.value, 10))}
                >
                  <option value="select-community" disabled>
                    Select a community
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
              <Alert variant="danger">Could not retrieve space groups from Circle. Please try again.</Alert>
            ) : (
              <>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-space-group`}>Select a space group</label>
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
                      Select a space group
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
                    Do not remove Circle access when membership ends
                  </label>
                ) : null}
                {product.variants.length > 0 ? (
                  <>
                    {product.variants.every(({ integrations }) => !integrations.circle) ? (
                      <Alert role="status" variant="warning">
                        {product.native_type === "membership"
                          ? "Your integration is not assigned to any tier. Check your tiers' settings."
                          : "Your integration is not assigned to any version. Check your versions' settings."}
                      </Alert>
                    ) : null}
                    <Toggle
                      value={product.variants.every(({ integrations }) => integrations.circle)}
                      onChange={setEnabledForOptions}
                    >
                      {product.native_type === "membership" ? "Enable for all tiers" : "Enable for all versions"}
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
