import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader, { Pagination } from "$app/components/Admin/PaginatedLoader";
import AdminPurchase, { type Purchase } from "$app/components/Admin/Purchases";

type PageProps = {
  purchases: Purchase[];
  pagination: Pagination;
};

const AdminComplianceCardsIndex = () => {
  const { purchases, pagination } = cast<PageProps>(usePage().props);

  return (
    <div className="flex flex-col gap-4">
      {purchases.map((purchase) => (
        <AdminPurchase key={purchase.id} purchase={purchase} />
      ))}
      {pagination.page === 1 && purchases.length === 0 && <EmptyState message="No purchases found." />}
      <PaginatedLoader itemsLength={purchases.length} pagination={pagination} only={["purchases", "pagination"]} />
    </div>
  );
};

export default AdminComplianceCardsIndex;
