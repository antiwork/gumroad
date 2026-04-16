import { usePage, router } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import AdminEmptyState from "$app/components/Admin/EmptyState";
import { Pagination, type PaginationProps } from "$app/components/Pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tabs, Tab } from "$app/components/ui/Tabs";

type ScheduledPayoutUser = {
  external_id: string;
  email: string;
  name: string | null;
};

type ScheduledPayout = {
  external_id: string;
  action: "refund" | "payout" | "hold";
  status: "pending" | "executed" | "cancelled" | "flagged" | "held";
  delay_days: number;
  scheduled_at: string;
  executed_at: string | null;
  payout_amount_cents: number | null;
  created_at: string;
  user: ScheduledPayoutUser;
  created_by: { name: string } | null;
};

type PageProps = {
  scheduled_payouts: ScheduledPayout[];
  pagination: PaginationProps;
  current_status_filter: string | null;
};

const STATUS_BADGE_STYLES: Record<string, string> = {
  pending: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200",
  executed: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
  cancelled: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200",
  flagged: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  held: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
};

const StatusBadge = ({ status }: { status: string }) => (
  <span
    className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium capitalize ${STATUS_BADGE_STYLES[status] ?? ""}`}
  >
    {status}
  </span>
);

const STATUS_FILTERS = [
  { value: null, label: "All" },
  { value: "pending", label: "Pending" },
  { value: "flagged", label: "Flagged" },
  { value: "executed", label: "Executed" },
  { value: "cancelled", label: "Cancelled" },
  { value: "held", label: "Held" },
];

const describeAction = (sp: ScheduledPayout): string => {
  const amount = formatPriceCentsWithCurrencySymbol("usd", sp.payout_amount_cents ?? 0, { symbolFormat: "short" });
  const completed = sp.status === "executed";

  switch (sp.action) {
    case "payout":
      return completed
        ? `Balance of ${amount} was paid out to the seller.`
        : `Balance of ${amount} will be paid out to the seller.`;
    case "refund":
      return completed
        ? `No payout. Balance (${amount}) was refunded to customers.`
        : `No payout. Balance (${amount}) will be refunded to customers.`;
    case "hold":
      return `Balance of ${amount} held for manual release.`;
  }
};

const AdminScheduledPayoutsIndex = () => {
  const { scheduled_payouts, pagination, current_status_filter } = cast<PageProps>(usePage().props);

  const onChangePage = (page: number) => {
    router.reload({ data: { page: page.toString(), status: current_status_filter ?? undefined } });
  };

  const onFilterStatus = (status: string | null) => {
    router.reload({ data: { status: status ?? undefined } });
  };

  return (
    <div className="flex flex-col gap-4">
      <Tabs>
        {STATUS_FILTERS.map(({ value, label }) => (
          <Tab
            key={value ?? "all"}
            isSelected={current_status_filter === value}
            onClick={(e) => {
              e.preventDefault();
              onFilterStatus(value);
            }}
            href="#"
          >
            {label}
          </Tab>
        ))}
      </Tabs>

      {scheduled_payouts.length === 0 ? (
        <AdminEmptyState message="No scheduled payouts found." />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>User</TableHead>
              <TableHead>Action</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Scheduled</TableHead>
              <TableHead>Created by</TableHead>
              <TableHead>Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {scheduled_payouts.map((sp) => (
              <TableRow key={sp.external_id}>
                <TableCell>
                  <a href={Routes.admin_user_path(sp.user.external_id)} className="hover:underline">
                    {sp.user.name || sp.user.email}
                  </a>
                </TableCell>
                <TableCell>
                  <div className="capitalize">{sp.action}</div>
                  <div className="text-xs text-muted">{describeAction(sp)}</div>
                </TableCell>
                <TableCell>
                  <StatusBadge status={sp.status} />
                </TableCell>
                <TableCell>{new Date(sp.scheduled_at).toLocaleDateString()}</TableCell>
                <TableCell>{sp.created_by?.name ?? "-"}</TableCell>
                <TableCell>
                  {(sp.status === "pending" || sp.status === "flagged") && (
                    <div className="flex gap-2">
                      <AdminActionButton
                        url={Routes.execute_admin_scheduled_payout_path(sp.external_id)}
                        label="Execute now"
                        confirm_message={`Execute ${sp.action} for ${sp.user.name || sp.user.email}?`}
                        success_message="Executed"
                      />
                      <AdminActionButton
                        url={Routes.cancel_admin_scheduled_payout_path(sp.external_id)}
                        label="Cancel"
                        confirm_message={`Cancel scheduled ${sp.action} for ${sp.user.name || sp.user.email}?`}
                        success_message="Cancelled"
                        color="danger"
                        outline
                      />
                    </div>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      {pagination.pages > 1 && <Pagination pagination={pagination} onChangePage={onChangePage} />}
    </div>
  );
};

export default AdminScheduledPayoutsIndex;
