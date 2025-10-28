import { usePage } from "@inertiajs/react";
import React from "react";

import { type Pagination } from "$app/hooks/useLazyFetch";

import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader from "$app/components/Admin/PaginatedLoader";
import User, { type User as UserType } from "$app/components/Admin/Users/User";

type PageProps = {
  users: UserType[];
  pagination: Pagination;
};

type Props = {
  is_affiliate_user?: boolean;
};

const AdminUsers = ({ is_affiliate_user = false }: Props) => {
  const { pagination, users } = usePage<PageProps>().props;

  return (
    <div className="paragraphs">
      {users.map((user) => (
        <User key={user.id} user={user} is_affiliate_user={is_affiliate_user} />
      ))}
      {pagination.page === 1 && users.length === 0 && <EmptyState message="No users found." />}
      <PaginatedLoader itemsLength={users.length} pagination={pagination} only={["users", "pagination"]} />
    </div>
  );
};

export default AdminUsers;
