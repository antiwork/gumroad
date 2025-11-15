import React from "react";

import { formatDate } from "$app/utils/date";

import type { User } from "$app/components/Admin/Users/User";
import { Icon } from "$app/components/Icons";
import { WithTooltip, type Position } from "$app/components/WithTooltip";

export type Props = {
  user: User;
  position?: Position;
};

const BlockedUserTooltip = ({ user, position = "bottom" }: Props) => {
  const { blocked_by_form_email_object, blocked_by_form_email_domain_object } = user;

  const isBlockedByFormEmail = blocked_by_form_email_object?.blocked_at;
  const isBlockedByFormEmailDomain = blocked_by_form_email_domain_object?.blocked_at;

  if (!isBlockedByFormEmail && !isBlockedByFormEmailDomain) {
    return null;
  }

  const content = () => (
    <div className="flex flex-col gap-4">
      {blocked_by_form_email_object?.blocked_at ? (
        <span>{`Email blocked ${formatDate(new Date(blocked_by_form_email_object.blocked_at))} (block created ${formatDate(new Date(blocked_by_form_email_object.created_at))})`}</span>
      ) : null}
      {blocked_by_form_email_domain_object?.blocked_at ? (
        <span>{`${user.form_email_domain} blocked ${formatDate(new Date(blocked_by_form_email_domain_object.blocked_at))} (block created ${formatDate(new Date(blocked_by_form_email_domain_object.created_at))})`}</span>
      ) : null}
    </div>
  );

  return (
    <WithTooltip tip={content()} position={position}>
      <Icon name="solid-shield-exclamation" style={{ color: "rgb(var(--warning))" }} />
    </WithTooltip>
  );
};

export default BlockedUserTooltip;
