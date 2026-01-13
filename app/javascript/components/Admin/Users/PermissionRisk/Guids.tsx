import { Link } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

type UserGuids = { guid: string; user_external_ids: string[] }[];

type GuidProps = {
  guid: string;
  user_external_ids: string[];
  className?: string;
};

const Guid = ({ guid, user_external_ids, className }: GuidProps) => (
  <div className={className}>
    <h5 className="grow font-bold">
      <Link href={Routes.admin_guid_path(guid)}>{guid}</Link>
    </h5>
    <span>{user_external_ids.length} users</span>
  </div>
);

const UserGuidsContent = ({ userGuids, isLoading }: { userGuids: UserGuids; isLoading: boolean }) => {
  if (isLoading) return <LoadingSpinner />;
  if (userGuids.length > 0)
    return (
      <Card>
        {userGuids.map(({ guid, user_external_ids }) => (
          <CardContent key={guid} asChild>
            <Guid guid={guid} user_external_ids={user_external_ids} />
          </CardContent>
        ))}
      </Card>
    );
  return (
    <Alert role="status" variant="info">
      No GUIDs found.
    </Alert>
  );
};

const AdminUserGuids = ({ user_external_id }: { user_external_id: string }) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [userGuids, setUserGuids] = React.useState<UserGuids>([]);

  const fetchUserGuids = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_guids_path(user_external_id, { format: "json" }),
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
