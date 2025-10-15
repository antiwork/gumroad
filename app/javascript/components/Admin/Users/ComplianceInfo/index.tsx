import React from "react";

import ComplianceInfo from "$app/components/Admin/Users/ComplianceInfo/ComplianceInfo";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserComplianceInfoProps = {
  user: User;
};

const AdminUserComplianceInfo = ({ user }: AdminUserComplianceInfoProps) => (
  <>
    <hr />
    <ComplianceInfo complianceInfo={user.alive_user_compliance_info} />
  </>
);

export default AdminUserComplianceInfo;
