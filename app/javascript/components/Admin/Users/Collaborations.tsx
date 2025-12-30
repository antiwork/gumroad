import { Link } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import type { Collaboration, User } from "$app/components/Admin/Users/User";

type CollaborationsProps = {
  user: User;
};

type CollaborationItemProps = {
  collaboration: Collaboration;
};

const CollaborationItem = ({ collaboration }: CollaborationItemProps) => (
  <div>
    <div className="flex items-center gap-4">
      <img
        src={collaboration.seller.avatar_url}
        className="user-avatar"
        alt={collaboration.seller.display_name_or_email}
      />
      <div className="grid">
        <h5>
          <Link href={Routes.admin_user_url(collaboration.seller.id)}>
            {collaboration.seller.display_name_or_email}
          </Link>
        </h5>
        <div>{collaboration.percent_commission}% commission</div>
      </div>
    </div>

    <div className="space-x-1">
      <span>since</span>
      <DateTimeWithRelativeTooltip date={collaboration.created_at} />
    </div>
  </div>
);

const Collaborations = ({ user: { collaborations } }: CollaborationsProps) =>
  collaborations.length > 0 && (
    <>
      <hr />
      <details>
        <summary>
          <h3>Collaborations</h3>
        </summary>
        <div className="stack">
          {collaborations.map((collaboration) => (
            <CollaborationItem key={collaboration.id} collaboration={collaboration} />
          ))}
        </div>
      </details>
    </>
  );

export default Collaborations;
