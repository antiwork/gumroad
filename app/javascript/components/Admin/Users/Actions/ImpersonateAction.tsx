import React from "react";

import { type User } from "$app/components/Admin/Users/User";
import { WithTooltip } from "$app/components/WithTooltip";

type ImpersonateActionProps = {
  user: User;
};

const ImpersonateAction = ({ user: { impersonatable, id: user_identifier } }: ImpersonateActionProps) =>
  impersonatable ? (
    <a href={Routes.admin_impersonate_url({ user_identifier })} className="button small">
      Become
    </a>
  ) : (
    <WithTooltip tip="User is either deleted, or a team member.">
      <a href="#" className="button small" data-disabled="true">
        Become
      </a>
    </WithTooltip>
  );

export default ImpersonateAction;
