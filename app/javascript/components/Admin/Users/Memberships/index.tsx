import React from "react";

import Membership from "$app/components/Admin/Users/Memberships/Membership";
import type { User } from "$app/components/Admin/Users/User";

type MembershipsProps = {
  user: User;
};

const Memberships = ({ user: { admin_manageable_user_memberships } }: MembershipsProps) =>
  admin_manageable_user_memberships.length > 0 && (
    <>
      <hr />
      <details>
        <summary>
          <h3>User memberships</h3>
        </summary>
        <div className="stack">
          {admin_manageable_user_memberships.map((membership) => (
            <Membership key={membership.id} membership={membership} />
          ))}
        </div>
      </details>
    </>
  );

export default Memberships;
