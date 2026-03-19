import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { NoIcon } from "$app/components/Admin/Icons";
import type { User } from "$app/components/Admin/Users/User";
import { DefinitionList } from "$app/components/ui/DefinitionList";

type FooterProps = {
  user: User;
};

const Footer = ({ user }: FooterProps) => (
  <div>
    <DefinitionList>
      <dt>Created</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={user.created_at} />
      </dd>
      <dt>Updated</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={user.updated_at} />
      </dd>
      <dt>Deleted</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={user.deleted_at} placeholder={<NoIcon />} />
      </dd>
    </DefinitionList>
  </div>
);

export default Footer;
