import { usePage } from "@inertiajs/react";
import React from "react";

import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader, { Pagination } from "$app/components/Admin/PaginatedLoader";
import { AdminPurchase, type Purchase } from "$app/components/Admin/Purchase";

const AdminComplianceCardsIndex = () => {
  const { purchases, pagination } = usePage<{ purchases: Purchase[]; pagination: Pagination }>().props;

  return (
    <div className="paragraphs">
      {purchases.map((purchase) => (
        <AdminPurchase key={purchase.id} purchase={purchase} />
      ))}
      {pagination.page === 1 && purchases.length === 0 && <EmptyState message="No purchases found." />}
      <PaginatedLoader itemsLength={purchases.length} pagination={pagination} only={["purchases", "pagination"]} />
    </div>
  );
};

export default AdminComplianceCardsIndex;
