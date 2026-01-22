import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminUserAndProductsTabs from "$app/components/Admin/UserAndProductsTabs";
import UserCard, { type User } from "$app/components/Admin/Users/User";

type PageProps = {
  user: User;
};

const AdminAffiliatesShow = () => {
  const { user } = cast<PageProps>(usePage().props);

  return (
    <div className="flex flex-col gap-4">
      <AdminUserAndProductsTabs selectedTab="profile" userExternalId={user.external_id} isAffiliateUser />
      <UserCard user={user} isAffiliateUser />
    </div>
  );
};

export default AdminAffiliatesShow;
