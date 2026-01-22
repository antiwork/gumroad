import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

type UserGuids = { guid: string; user_external_ids: string[] }[];

const AdminUserGuids = ({ user_external_id }: { user_external_id: string }) => {
  const [userGuids, setUserGuids] = React.useState<UserGuids | null>(null);

  const fetchUserGuids = async () => {
    if (userGuids) return;
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: Routes.admin_user_guids_path(user_external_id, { format: "json" }),
      });
      setUserGuids(cast<UserGuids>(await response.json()));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  return (
    <details>
      <summary onClick={() => void fetchUserGuids()}>
        <h3>GUIDs</h3>
      </summary>
      {userGuids ? (
        userGuids.length > 0 ? (
          <Card>
            {userGuids.map((guidData) => (
              <CardContent key={guidData.guid}>
                <h5 className="grow font-bold">
                  <a href={`/admin/guids/${guidData.guid}`}>{guidData.guid}</a>
                </h5>
                <span>{guidData.user_external_ids.length} users</span>
              </CardContent>
            ))}
          </Card>
        ) : (
          <Alert role="status" variant="info">
            No GUIDs found.
          </Alert>
        )
      ) : (
        <LoadingSpinner className="size-3" />
      )}
    </details>
  );
};

export default register({ component: AdminUserGuids, propParser: createCast() });
