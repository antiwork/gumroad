import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader, { type Pagination } from "$app/components/Admin/PaginatedLoader";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type RevenueSource = "sales" | "collaborator" | "affiliate" | "credit";

type UnreviewedUser = {
  id: number;
  external_id: string;
  name: string;
  email: string;
  unpaid_balance_cents: number;
  revenue_sources: RevenueSource[];
  admin_url: string;
  created_at: string;
};

type PageProps = {
  users: UnreviewedUser[];
  pagination: Pagination;
  total_count: number;
  cutoff_date: string;
};

const RevenueBadge = ({ type }: { type: RevenueSource }) => {
  const styles: Record<RevenueSource, string> = {
    sales: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
    collaborator: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
    affiliate: "bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200",
    credit: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
  };

  return (
    <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${styles[type]}`}>{type}</span>
  );
};

const UnreviewedUsersPage = () => {
  const { users, pagination, total_count, cutoff_date } = usePage<PageProps>().props;

  if (users.length === 0 && pagination.page === 1) {
    return <EmptyState message="No unreviewed users with unpaid balance found." />;
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="text-sm text-muted">
        Showing {users.length} of {total_count} unreviewed users with unpaid balance &gt; $10 (created since{" "}
        {cutoff_date})
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>User</TableHead>
            <TableHead>Name</TableHead>
            <TableHead>Email</TableHead>
            <TableHead>Revenue sources</TableHead>
            <TableHead className="text-right">Unpaid balance</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {users.map((user) => (
            <TableRow key={user.external_id}>
              <TableCell>
                <Link href={user.admin_url} className="text-accent hover:underline">
                  {user.external_id}
                </Link>
              </TableCell>
              <TableCell>
                <Link href={user.admin_url} className="hover:underline">
                  {user.name || "-"}
                </Link>
              </TableCell>
              <TableCell>
                <Link href={user.admin_url} className="hover:underline">
                  {user.email}
                </Link>
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap gap-1">
                  {user.revenue_sources.map((source) => (
                    <RevenueBadge key={source} type={source} />
                  ))}
                </div>
              </TableCell>
              <TableCell className="text-right font-mono">
                {formatPriceCentsWithCurrencySymbol("usd", user.unpaid_balance_cents, {
                  symbolFormat: "short",
                  noCentsIfWhole: true,
                })}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <PaginatedLoader itemsLength={users.length} pagination={pagination} only={["users", "pagination"]} />
    </div>
  );
};

export default UnreviewedUsersPage;
