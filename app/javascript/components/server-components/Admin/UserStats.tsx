import * as React from "react";
import { createCast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

const AdminUserStats = ({ user_id }: { user_id: number }) => {
  const [userStats, setUserStats] = React.useState<string | null>(null);

  useRunOnce(() => {
    const fetchUserStats = async () => {
      try {
        const response = await request({
          method: "GET",
          accept: "html",
          url: Routes.stats_admin_user_path(user_id),
        });
        setUserStats(await response.text());
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    };

    void fetchUserStats();
  });

  return userStats ? (
    <ul className="inline" dangerouslySetInnerHTML={{ __html: userStats }} />
  ) : (
    <div role="progressbar" style={{ display: "inline-block", width: "0.75em" }} />
  );
};

export default register({ component: AdminUserStats, propParser: createCast() });
