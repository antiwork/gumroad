import { usePage } from "@inertiajs/react";
import React from "react";

import AdminUserActions from "$app/components/Admin/Users/Actions";
import AdminUserAddCredit from "$app/components/Admin/Users/AddCredit";
import AdminUserChangeEmail from "$app/components/Admin/Users/ChangeEmail";
import AdminUserComments from "$app/components/Admin/Users/Comments";
import AdminUserComplianceInfo, { type ComplianceInfoProps } from "$app/components/Admin/Users/ComplianceInfo";
import AdminUserCustomFee from "$app/components/Admin/Users/CustomFee";
import AdminUserEmailChanges from "$app/components/Admin/Users/EmailChanges";
import Footer from "$app/components/Admin/Users/Footer";
import Header from "$app/components/Admin/Users/Header";
import AdminUserMassTransferPurchases from "$app/components/Admin/Users/MassTransferPurchases";
import AdminUserMemberships from "$app/components/Admin/Users/Memberships";
import AdminUserMerchantAccounts from "$app/components/Admin/Users/MerchantAccounts";
import AdminUserPayoutInfo from "$app/components/Admin/Users/PayoutInfo";
import AdminUserPermissionRisk from "$app/components/Admin/Users/PermissionRisk";

export type Seller = {
  external_id: string;
  display_name_or_email: string;
  avatar_url: string;
};

export type UserMembership = {
  id: number;
  seller: Seller;
  role: string;
  last_accessed_at: string | null;
  created_at: string;
};

type BlockedObject = {
  blocked_at: string | null;
  created_at: string;
};

export type User = {
  external_id: string;
  email: string;
  support_email?: string | null;
  name: string | null;
  avatar_url: string;
  username: string;
  profile_url: string;
  form_email: string;
  blocked_by_form_email_object: BlockedObject | null;
  form_email_domain: string;
  blocked_by_form_email_domain_object: BlockedObject | null;
  subdomain_with_protocol: string;
  custom_fee_per_thousand: number | null;
  impersonatable: boolean;
  verified: boolean | null;
  all_adult_products: boolean;
  admin_manageable_user_memberships: UserMembership[];
  alive_user_compliance_info?: ComplianceInfoProps | null;
  compliant?: boolean | null;
  suspended: boolean;
  unpaid_balance_cents: number;
  disable_paypal_sales: boolean;
  flagged_for_fraud: boolean;
  flagged_for_tos_violation: boolean;
  on_probation: boolean;
  user_risk_state: string;
  comments_count: number;
  bio: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
};

export type Props = {
  user: User;
  isAffiliateUser?: boolean;
};

const UserCard = ({ user, isAffiliateUser = false }: Props) => {
  const page = usePage();
  const { url } = page;

  return (
    <div className="grid gap-4 rounded border border-border bg-background p-4" data-user-id={user.external_id}>
      <Header user={user} isAffiliateUser={isAffiliateUser} url={url} />

      <hr />

      <AdminUserActions user={user} />
      <AdminUserMemberships user={user} />
      <AdminUserPermissionRisk user={user} />
      <AdminUserComplianceInfo user={user} />
      <hr />
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <AdminUserPayoutInfo user={user} />
        <hr className="block md:hidden" />
        <AdminUserMerchantAccounts user={user} />
      </div>
      <AdminUserEmailChanges user={user} />
      <AdminUserChangeEmail user={user} />
      <AdminUserCustomFee user={user} />
      <AdminUserAddCredit user={user} />
      <AdminUserMassTransferPurchases user={user} />
      <AdminUserComments user={user} />

      <hr />

      <Footer user={user} />
    </div>
  );
};

export default UserCard;
