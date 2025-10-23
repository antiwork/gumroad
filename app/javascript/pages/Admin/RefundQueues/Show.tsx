import { usePage } from "@inertiajs/react";
import React from "react";

import EmptyState from "$app/components/Admin/EmptyState";
import UserCard, { type User } from "$app/components/Admin/Users/User";

const AdminRefundQueue = () => {
  const { users } = usePage<{ users: User[] }>().props;

  return (
    <section className="flex flex-col gap-4">
      {users.map((user) => (
        <UserCard key={user.id} user={user} is_affiliate_user={false} />
      ))}
      {users.length === 0 && <EmptyState message="No users found." />}
    </section>
  );
};

export default AdminRefundQueue;
