import { Link } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import type { IncomingCollaboration, User, UserMembership } from "$app/components/Admin/Users/User";

type MembershipsProps = {
  user: User;
};

type MembershipProps = {
  membership: UserMembership;
};

type CollaborationProps = {
  collaboration: IncomingCollaboration;
};

const Membership = ({ membership }: MembershipProps) => (
  <div>
    <div className="flex items-center gap-4">
      <img src={membership.seller.avatar_url} className="user-avatar" alt={membership.seller.display_name_or_email} />
      <div className="grid">
        <h5>
          <Link href={Routes.admin_user_url(membership.seller.id)}>{membership.seller.display_name_or_email}</Link>
        </h5>
        <div>{membership.role}</div>
      </div>
    </div>
    <div className="text-right">
      {membership.last_accessed_at ? (
        <div className="space-x-1">
          <span>last accessed</span>
          <DateTimeWithRelativeTooltip date={membership.last_accessed_at} />
        </div>
      ) : null}
    </div>
    <div className="space-x-1">
      <span>invited</span>
      <DateTimeWithRelativeTooltip date={membership.created_at} />
    </div>
  </div>
);

const Collaboration = ({ collaboration }: CollaborationProps) => (
  <div>
    <div className="flex items-center gap-4">
      <img
        src={collaboration.seller.avatar_url}
        className="user-avatar"
        alt={collaboration.seller.display_name_or_email}
      />
      <div className="grid">
        <h5>
          <Link href={Routes.admin_user_url(collaboration.seller.id)}>{collaboration.seller.display_name_or_email}</Link>
        </h5>
        <div className="flex gap-2">
          {collaboration.invitation_accepted ? (
            <span className="text-green-600">Accepted</span>
          ) : (
            <span className="text-yellow-600">Pending</span>
          )}
          {collaboration.percent_commission != null && <span>{collaboration.percent_commission}% commission</span>}
        </div>
      </div>
    </div>
    <div className="space-x-1">
      <span>added</span>
      <DateTimeWithRelativeTooltip date={collaboration.created_at} />
    </div>
  </div>
);

const Memberships = ({ user: { admin_manageable_user_memberships, incoming_collaborations } }: MembershipsProps) => {
  const hasMemberships = admin_manageable_user_memberships.length > 0;
  const hasCollaborations = incoming_collaborations.length > 0;

  if (!hasMemberships && !hasCollaborations) return null;

  return (
    <>
      <hr />
      {hasMemberships && (
        <details>
          <summary>
            <h3>Team memberships ({admin_manageable_user_memberships.length})</h3>
          </summary>
          <div className="stack">
            {admin_manageable_user_memberships.map((membership) => (
              <Membership key={membership.id} membership={membership} />
            ))}
          </div>
        </details>
      )}
      {hasCollaborations && (
        <details>
          <summary>
            <h3>Collaborations ({incoming_collaborations.length})</h3>
          </summary>
          <div className="stack">
            {incoming_collaborations.map((collaboration) => (
              <Collaboration key={collaboration.id} collaboration={collaboration} />
            ))}
          </div>
        </details>
      )}
    </>
  );
};

export default Memberships;
