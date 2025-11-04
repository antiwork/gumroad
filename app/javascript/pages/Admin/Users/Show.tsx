import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminUserAndProductsTabs from "$app/components/Admin/UserAndProductsTabs";
import UserCard, { type User } from "$app/components/Admin/Users/User";

type PageProps = {
  user: User;
};

type Props = {
  isAffiliateUser?: boolean;
};

const AdminUsersShow = ({ isAffiliateUser = false }: Props) => {
  const { user } = cast<PageProps>(usePage().props);

  return (
    <div className="paragraphs">
      <AdminUserAndProductsTabs selectedTab="profile" userId={user.id} />
      <UserCard user={user} isAffiliateUser={isAffiliateUser} />
    </div>
  );
};

export default AdminUsersShow;
