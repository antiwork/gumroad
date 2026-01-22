import React from "react";

import { type User } from "$app/components/Admin/Users/User";
import { buttonVariants } from "$app/components/Button";
import { WithTooltip } from "$app/components/WithTooltip";

type ImpersonateActionProps = {
  user: User;
};

const ImpersonateAction = ({ user: { impersonatable, username: user_identifier } }: ImpersonateActionProps) =>
  impersonatable ? (
    <a href={Routes.admin_impersonate_url({ user_identifier })} className={buttonVariants({ size: "sm" })}>
      Become
    </a>
  ) : (
    <WithTooltip tip="User is either deleted, or a team member.">
      <a href="#" className={buttonVariants({ size: "sm" })} data-disabled="true">
        Become
      </a>
    </WithTooltip>
  );

export default ImpersonateAction;
