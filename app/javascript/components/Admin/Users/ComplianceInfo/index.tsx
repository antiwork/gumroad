import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import ComplianceInfo, { type ComplianceInfoProps } from "$app/components/Admin/Users/ComplianceInfo/ComplianceInfo";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserComplianceInfoProps = {
  user: User;
};

const AdminUserComplianceInfo = ({ user }: AdminUserComplianceInfoProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [complianceInfo, setComplianceInfo] = React.useState<ComplianceInfoProps | null>(null);

  const fetchComplianceInfo = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_compliance_info_path(user.id),
      accept: "json",
    });
    const data = cast<{ compliance_info: ComplianceInfoProps | null }>(await response.json());
    setComplianceInfo(data.compliance_info);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchComplianceInfo();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Compliance Info</h3>
        </summary>
        <ComplianceInfo complianceInfo={complianceInfo} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminUserComplianceInfo;
