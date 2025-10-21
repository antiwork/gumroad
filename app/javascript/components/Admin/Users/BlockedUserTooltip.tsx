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
  const { form_email_block, form_email_domain, form_email_domain_block } = user;

  if (!form_email_block && !form_email_domain_block) {
    return null;
  }

  const content = () => (
    <div className="paragraphs">
      {form_email_block ? (
        <span>{`Email blocked ${formatDate(new Date(form_email_block.blocked_at))} (block created ${formatDate(new Date(form_email_block.created_at))})`}</span>
      ) : null}
      {form_email_domain_block ? (
        <span>{`${form_email_domain} blocked ${formatDate(new Date(form_email_domain_block.blocked_at))} (block created ${formatDate(new Date(form_email_domain_block.created_at))})`}</span>
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
