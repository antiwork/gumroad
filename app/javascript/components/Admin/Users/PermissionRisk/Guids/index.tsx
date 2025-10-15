import * as React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import Loading from "$app/components/Admin/Loading";
import Guid from "$app/components/Admin/Users/PermissionRisk/Guids/Guid";

type UserGuids = { guid: string; user_ids: number[] }[];

const UserGuidsContent = ({ userGuids, isLoading }: { userGuids: UserGuids; isLoading: boolean }) => {
  if (isLoading) return <Loading />;
  if (userGuids.length > 0)
    return (
      <div className="stack">
        {userGuids.map(({ guid, user_ids }) => (
          <Guid key={guid} guid={guid} user_ids={user_ids} />
        ))}
      </div>
    );
  return (
    <div className="info" role="status">
      No GUIDs found.
    </div>
  );
};

const AdminUserGuids = ({ user_id }: { user_id: number }) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [userGuids, setUserGuids] = React.useState<UserGuids>([]);

  const fetchUserGuids = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_compliance_guids_path(user_id, { format: "json" }),
      accept: "json",
    });
    setUserGuids(cast<UserGuids>(await response.json()));
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchUserGuids();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>GUIDs</h3>
        </summary>
        <UserGuidsContent userGuids={userGuids} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminUserGuids;
