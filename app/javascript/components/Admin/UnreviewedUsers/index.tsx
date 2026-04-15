import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import EmptyState from "$app/components/Admin/EmptyState";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type RevenueSource = "sales" | "collaborator" | "affiliate" | "credit";

type UnreviewedUser = {
  external_id: string;
  name: string;
  email: string;
  unpaid_balance_cents: number;
  revenue_sources: RevenueSource[];
  payout_method: string | null;
  account_age_days: number;
  admin_url: string;
  created_at: string;
};

type PageProps = {
  users: UnreviewedUser[];
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
  const { users, total_count, cutoff_date } = usePage<PageProps>().props;

  if (users.length === 0) {
    return <EmptyState message="No unreviewed users with unpaid balance found." />;
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="text-sm text-muted">
        Top {users.length.toLocaleString()} of {total_count.toLocaleString()} unreviewed users with unpaid balance &gt;
        $10 (created since {cutoff_date})
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>User</TableHead>
            <TableHead>Name</TableHead>
            <TableHead>Email</TableHead>
            <TableHead>Revenue sources</TableHead>
            <TableHead>Payout method</TableHead>
            <TableHead>Account age</TableHead>
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
              <TableCell>{user.payout_method || ""}</TableCell>
              <TableCell>{user.account_age_days}d</TableCell>
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
    </div>
  );
};

export default UnreviewedUsersPage;
