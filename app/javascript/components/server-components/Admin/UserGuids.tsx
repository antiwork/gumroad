import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { showAlert } from "$app/components/server-components/Alert";

type UserGuids = { guid: string; user_ids: number[] }[];

const AdminUserGuids = ({ user_id }: { user_id: number }) => {
  const [userGuids, setUserGuids] = React.useState<UserGuids | null>(null);

  const fetchUserGuids = async () => {
    if (userGuids) return;
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: Routes.admin_compliance_guids_path(user_id, { format: "json" }),
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
          <div className="stack">
            {userGuids.map((guidData) => (
              <div key={guidData.guid}>
                <h5>
                  <a href={`/admin/guids/${guidData.guid}`}>{guidData.guid}</a>
                </h5>
                <span>{guidData.user_ids.length} users</span>
              </div>
            ))}
          </div>
        ) : (
          <div role="status" className="info">
            No GUIDs found.
          </div>
        )
      ) : (
        <div role="progressbar" style={{ display: "inline-block", width: "0.75em" }} />
      )}
    </details>
  );
};

export default register({ component: AdminUserGuids, propParser: createCast() });
