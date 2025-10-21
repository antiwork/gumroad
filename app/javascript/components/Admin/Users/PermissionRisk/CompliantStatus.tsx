import classNames from "classnames";
import React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { WithTooltip } from "$app/components/WithTooltip";

type CompliantStatusProps = {
  user: User;
};

const CompliantStatus = ({ user }: CompliantStatusProps) => (
  <div>
    <WithTooltip tip="Risk state" position="left">
      <div className={classNames("pill small", user.compliant ? "success" : "warning")}>{user.user_risk_state}</div>
    </WithTooltip>
  </div>
);

export default CompliantStatus;
