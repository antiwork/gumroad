import { usePage } from "@inertiajs/react";
import React from "react";

import EmptyState from "$app/components/Admin/EmptyState";
import UserCard, { type User } from "$app/components/Admin/Users/User";
import PaginatedLoader, { type Pagination } from "$app/components/Admin/PaginatedLoader";

type PageProps = {
  users: User[];
  pagination: Pagination;
};

const AdminRefundQueue = () => {
  const { pagination,users } = usePage<PageProps>().props;

  return (
    <section className="flex flex-col gap-4">
      {users.map((user) => (
        <UserCard key={`refund-queue-user-${user.id}`} user={user} />
      ))}
      {pagination.page === 1 && users.length === 0 && <EmptyState message="No users found." />}
      <PaginatedLoader itemsLength={users.length} pagination={pagination} only={["users", "pagination"]} />
    </section>
  );
};

export default AdminRefundQueue;
